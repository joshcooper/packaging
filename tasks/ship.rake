namespace :pl do
  desc "Ship mocked rpms to #{@build.yum_host}"
  task :ship_rpms do
    ["el", "fedora"].each do |dist|
      retry_on_fail(:times => 3) do
        pkgs = Dir["pkg/#{dist}/**/*.rpm"].map { |f| "'#{f.gsub("pkg/#{dist}/", "#{@build.yum_repo_path}/#{dist}/")}'"}
        rsync_to("pkg/#{dist}", @build.yum_host, @build.yum_repo_path)
        remote_set_immutable(@build.yum_host, pkgs)
      end
    end
  end

  namespace :remote do
    # These hacky bits execute a pre-existing rake task on the @build.apt_host
    # The rake task takes packages in a specific directory and freights them
    # to various target yum and apt repositories based on their specific type
    # e.g., final vs devel vs PE vs FOSS packages

    desc "Update remote rpm repodata on #{@build.yum_host}"
    task :update_yum_repo do
      STDOUT.puts "Really run remote repo update on #{@build.yum_host}? [y,n]"
      if ask_yes_or_no
        remote_ssh_cmd(@build.yum_host, 'rake -f /opt/repository/Rakefile mk_repo')
      end
    end

    desc "remote freight packages to repos on #{@build.apt_host}"
    task :freight do
      STDOUT.puts "Really run remote freight command on #{@build.apt_host}? [y,n]"
      if ask_yes_or_no
        override = "OVERRIDE=1" if ENV['OVERRIDE']
        remote_ssh_cmd(@build.apt_host, "rake -f /opt/repository/Rakefile freight #{override}")
      end
    end
  end

  desc "Ship cow-built debs to #{@build.apt_host}"
  task :ship_debs do
    retry_on_fail(:times => 3) do
      rsync_to('pkg/deb/', @build.apt_host, @build.apt_repo_path)
    end
  end

  namespace :remote do
  end

  desc "Update remote ips repository on #{@build.ips_host}"
  task :update_ips_repo do
    rsync_to('pkg/ips/pkgs/', @build.ips_host, @build.ips_store)
    remote_ssh_cmd(@build.ips_host, "pkgrecv -s #{@build.ips_store}/pkgs/#{@build.project}@build.#{@build.ipsversion}.p5p -d #{@build.ips_repo} \\*")
    remote_ssh_cmd(@build.ips_host, "pkgrepo refresh -s #{@build.ips_repo}")
    remote_ssh_cmd(@build.ips_host, "/usr/sbin/svcadm restart svc:/application/pkg/server")
  end if @build.build_ips

  desc "Upload ips p5p packages to downloads"
  task :ship_ips => 'pl:fetch' do
    if Dir['pkg/ips/pkgs/**/*'].empty?
      STDOUT.puts "There aren't any p5p packages in pkg/ips/pkgs. Maybe something went wrong?"
    else
      rsync_to('pkg/ips/pkgs/', @build.ips_package_host, @build.ips_path)
    end
  end if @build.build_ips

  # We want to ship a gem only for projects that build gems
  if @build.build_gem
    desc "Ship built gem to rubygems"
    task :ship_gem do
      # Even if a project builds a gem, if it uses the odd_even strategy, we only
      # want to ship final gems because otherwise a development gem would be
      # preferred over the last final gem
      if @build.version_strategy != "odd_even" || is_final?
        FileList["pkg/#{@build.project}-#{@build.gemversion}*.gem"].each do |f|
          puts "Shipping gem #{f} to rubygems"
          ship_gem(f)
        end
      else
        STDERR.puts "Not shipping development gem using odd_even strategy for the sake of your users."
      end
    end
  end

  desc "ship apple dmg to #{@build.yum_host}"
  task :ship_dmg => 'pl:fetch' do
    retry_on_fail(:times => 3) do
      rsync_to('pkg/apple/*.dmg', @build.yum_host, @build.dmg_path)
    end
  end if @build.build_dmg

  desc "ship tarball and signature to #{@build.tar_host}"
  task :ship_tar => 'pl:fetch' do
    retry_on_fail(:times => 3) do
      rsync_to("pkg/#{@build.project}-#{@build.version}.tar.gz*", @build.tar_host, @build.tarball_path)
    end
  end

  desc "UBER ship: ship all the things in pkg"
  task :uber_ship => 'pl:fetch' do
    if confirm_ship(FileList["pkg/**/*"])
      ENV['ANSWER_OVERRIDE'] = 'yes'
      Rake::Task["pl:ship_gem"].invoke if @build.build_gem
      Rake::Task["pl:ship_rpms"].invoke
      Rake::Task["pl:ship_debs"].invoke
      Rake::Task["pl:ship_dmg"].execute if @build.build_dmg
      Rake::Task["pl:ship_tar"].execute
      Rake::Task["pl:jenkins:ship"].invoke("shipped")
      add_shipped_metrics(:pe_version => ENV['PE_VER'], :is_rc => (! is_final?)) if @build.benchmark
      post_shipped_metrics if @build.benchmark
    else
      puts "Ship canceled"
      exit
    end
  end

  # It is odd to namespace this ship task under :jenkins, but this task is
  # intended to be a component of the jenkins-based build workflow even if it
  # doesn't interact with jenkins directly. The :target argument is so that we
  # can invoke this task with a subdirectory of the standard distribution
  # server path. That way we can separate out built artifacts from
  # signed/actually shipped artifacts e.g. $path/shipped/ or $path/artifacts.
  namespace :jenkins do
    desc "Ship pkg directory contents to distribution server"
    task :ship, :target do |t, args|
      invoke_task("pl:fetch")
      target = args.target || "artifacts"
      artifact_dir = "#{@build.jenkins_repo_path}/#{@build.project}/#{@build.ref}/#{target}"

      # In order to get a snapshot of what this build looked like at the time
      # of shipping, we also generate and ship the params file
      #
      @build.params_to_yaml('pkg')


      # Sadly, the packaging repo cannot yet act on its own, without living
      # inside of a packaging-repo compatible project. This means in order to
      # use the packaging repo for shipping and signing (things that really
      # don't require build automation, specifically) we still need the project
      # clone itself.
      git_bundle('HEAD', 'signing_bundle', 'pkg')

      retry_on_fail(:times => 3) do
        remote_ssh_cmd(@build.distribution_server, "mkdir -p #{artifact_dir}")
      end
      retry_on_fail(:times => 3) do
        ignore_existing = "--ignore-existing"
        rsync_to("pkg/", @build.distribution_server, "#{artifact_dir}/ #{ignore_existing} --exclude repo_configs")
      end
      # If we just shipped a tagged version, we want to make it immutable
      files = Dir.glob("pkg/**/*").select { |f| File.file?(f) }.map do |file|
        "#{artifact_dir}/#{file.sub(/^pkg\//,'')}"
      end
      remote_set_immutable(@build.distribution_server, files)
    end

    desc "Ship generated repository configs to the distribution server"
    task :ship_repo_configs do
      empty_dir?("pkg/repo_configs") and fail "No repo configs have been generated! Try pl:deb_repo_configs or pl:rpm_repo_configs"
      invoke_task("pl:fetch")
      repo_dir = "#{@build.jenkins_repo_path}/#{@build.project}/#{@build.ref}/repo_configs"
      remote_ssh_cmd(@build.distribution_server, "mkdir -p #{repo_dir}")
      retry_on_fail(:times => 3) do
        rsync_to("pkg/repo_configs/", @build.distribution_server, repo_dir)
      end
    end
  end
end


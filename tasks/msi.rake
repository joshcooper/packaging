def heat(fragment_dir, wxs_file)
  puts "heat dir #{fragment_dir} -out #{wxs_file}"
end

def candle(wxs_file, options = {})
  puts "candle #{wxs_file}"
end

def light(obj_files, dest, options = {})
  puts "light #{obj_files.join(' ')} -out #{dest}"
end

namespace :package do
  namespace :msi do
    work_dir = get_temp
    fragments_dir = File.join(work_dir, 'fragments')
    obj_dir = File.join(work_dir, 'obj')
    dest_dir = "pkg/msi"
    dest_msi = File.join(dest_dir, "#{@build.project}.msi")

    mkdir_pr fragments_dir, obj_dir, dest_dir

    desc "Create an msi package"
    task :package => [ :compile ] do
      obj_files = FileList["#{obj_dir}/*.wixobj"]

      light(obj_files, dest_msi)
      FileUtils.touch(dest_msi)
    end

    desc "Compile wix source files into object files"
    task :compile => :preprocess do
      FileList["ext/msi/*.wxs", fragments_dir].each do |wxs|
        name = File.basename(wxs)
        candle(wxs)
        FileUtils.touch(File.join(obj_dir, "#{name + ".wixobj"}"))
      end
    end

    desc "Create a wix fragment containing one component for each file in the project"
    task :preprocess do
      fragment = "#{fragments_dir}/#{@build.project}.wxs"
      heat("lib", fragment)
      FileUtils.touch(fragment)
    end
  end

  namespace :pl do
    task :msi => ["package:msi"]
  end
end

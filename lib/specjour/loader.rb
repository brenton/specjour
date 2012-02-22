module Specjour
  class Loader
    include Protocol
    include Fork

    attr_reader :test_paths, :printer_uri, :project_path, :task, :worker_size, :worker_pids, :quiet

    def initialize(options = {})
      @options = options
      @printer_uri = options[:printer_uri]
      @test_paths = options[:test_paths]
      @worker_size = options[:worker_size]
      @task = options[:task]
      @quiet = options[:quiet]
      @project_path = options[:project_path]
      @worker_pids = []
      Dir.chdir project_path
      Specjour.load_custom_hooks
    end

    def start
      load_app
      Configuration.after_load.call
      (1..worker_size).each do |index|
        worker_pids << fork do
          w = Worker.new(
            :number => index,
            :printer_uri => printer_uri,
            :quiet => quiet
          ).send(task)
        end
      end
      Process.waitall
    ensure
      kill_worker_processes
    end

    def spec_files
      @spec_files ||= file_collector(spec_paths) do |path|
        if path == project_path
          Dir["#{path}/spec/**/*_spec.rb"]
        else
          Dir["#{path}/**/*_spec.rb"]
        end
      end
    end

    def feature_files
      @feature_files ||= file_collector(feature_paths) do |path|
        if path == project_path
          Dir["#{path}/features/**/*.feature"]
        else
          Dir["#{path}/**/*.feature"]
        end
      end
    end

    protected

    def spec_paths
      @spec_paths ||= test_paths.select {|p| p =~ /spec.*$/}
    end

    def feature_paths
      @feature_paths ||= test_paths.select {|p| p =~ /features.*$/}
    end

    def file_collector(paths, &globber)
      if spec_paths.empty? && feature_paths.empty?
        globber[project_path]
      else
        paths.map do |path|
          path = File.expand_path(path, project_path)
          if File.directory?(path)
            globber[path]
          else
            path
          end
        end.flatten.uniq
      end
    end

    def load_app
      share_examples if spec_files.any?
      share_features if feature_files.any?
    end

    def share_examples
      RSpec::Preloader.load spec_files
      connection.send_message :tests=, filtered_examples
    ensure
      ::RSpec.reset
    end

    def share_features
      Cucumber::Preloader.load
      connection.send_message :tests=, feature_files
    end

    def filtered_examples
      ::RSpec.world.example_groups.map do |g|
        g.descendants.map do |gs|
          gs.examples
        end.flatten.map do |e|
          "#{e.file_path}:#{e.metadata[:line_number]}"
        end
      end.flatten.uniq
    end

    def kill_worker_processes
      if Specjour.interrupted?
        Process.kill('INT', *worker_pids) rescue Errno::ESRCH
      else
        Process.kill('TERM', *worker_pids) rescue Errno::ESRCH
      end
    end

    def connection
      @connection ||= begin
        at_exit { connection.disconnect }
        printer_connection
      end
    end

    def printer_connection
      Connection.new URI.parse(printer_uri)
    end
  end
end
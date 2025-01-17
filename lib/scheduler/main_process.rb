module Scheduler
  class MainProcess

    # @return [Integer] pid of the main process.
    attr_accessor :pid
    # @return [String] a logger file.
    attr_accessor :logger
    # @return [Class] the class of the main job model.
    attr_accessor :job_class
    # @return [Integer] how much time to wait before each iteration.
    attr_accessor :polling_interval
    # @return [Integer] maximum number of concurent jobs.
    attr_accessor :max_concurrent_jobs

    ##
    # Creates a MainProcess which keeps running
    # and continuously checks if new jobs are queued.
    #
    # @return [Scheduler::MainProcess] the created MainProcess.
    def initialize
      Mongoid.load! Scheduler.configuration.mongoid_config_file, Scheduler.configuration.environment
      @logger = Scheduler.logger
      @pid = Process.pid
      @job_class = Scheduler.configuration.job_class
      @polling_interval = Scheduler.configuration.polling_interval
      @max_concurrent_jobs = Scheduler.configuration.max_concurrent_jobs

      if @polling_interval < 1
        logger.warn Rainbow("[Scheduler:#{@pid}] Warning: specified a polling interval lesser than 1: "\
          "it will be forced to 1.").yellow
        @polling_interval = 1
      end
      
      unless @job_class.included_modules.include? Scheduler::Schedulable
        raise "The given job class '#{@job_class}' is not a Schedulable class. "\
          "Make sure to add 'include Scheduler::Schedulable' to your class."
      end

      # Loads up a job queue.
      @queue = []

      @logger.info Rainbow("[Scheduler:#{@pid}] Starting main loop..").cyan
      self.start_loop
    end
  
    ##
    # Main loop.
    #
    # @return [nil]
    def start_loop
      loop do
        begin
          # Counts jobs to schedule.
          running_jobs = @job_class.running.entries
          schedulable_jobs = @job_class.queued.order_by(scheduled_at: :asc).entries
          jobs_to_schedule = @max_concurrent_jobs - running_jobs.count
          jobs_to_schedule = 0 if jobs_to_schedule < 0
  
          # Finds out scheduled jobs waiting to be performed.
          scheduled_jobs = []
          schedulable_jobs.first(jobs_to_schedule).each do |job|
            job_pid = Process.fork do
              begin
                job.perform(Process.pid)
              rescue StandardError => e
                @logger.error Rainbow("[Scheduler:#{@pid}] Error #{e.class}: #{e.message}.").red
                @logger.error Rainbow(e.backtrace.join("\n")).red
              end
            end
            Process.detach(job_pid)
            scheduled_jobs << job
            @queue << job.id.to_s
          end
  
          # Logs launched jobs
          if scheduled_jobs.any?
            @logger.info Rainbow("[Scheduler:#{@pid}] Launched #{scheduled_jobs.count} "\
              "jobs: #{scheduled_jobs.map(&:id).map(&:to_s).join(', ')}.").cyan
          else
            if schedulable_jobs.count == 0
              @logger.info Rainbow("[Scheduler:#{@pid}] No jobs in queue.").cyan
            else
              @logger.warn Rainbow("[Scheduler:#{@pid}] No jobs launched, reached maximum "\
                "number of concurrent jobs. Jobs in queue: #{schedulable_jobs.count}.").yellow
            end
          end
  
          # Checks for completed jobs: clears up queue and kills any zombie pid
          @queue.delete_if do |job_id|
            job = @job_class.find(job_id)
            if job.present?
              unless job.status.in? [ :queued, :running ]
                begin
                  @logger.info Rainbow("[Scheduler:#{@pid}] Removed process #{job.pid}, job is completed.").cyan
                  Process.kill :QUIT, job.pid
                rescue Errno::ENOENT, Errno::ESRCH
                end
                next true
              end
            end
            false
          end
  
          # Waits the specified amount of time before next iteration
          sleep @polling_interval
        rescue StandardError => error
          @logger.error Rainbow("[Scheduler:#{@pid}] Error #{error.class}: #{error.message}").red
          @logger.error Rainbow(error.backtrace.join("\n")).red
        rescue SignalException => signal
          if signal.message.in? [ 'SIGINT', 'SIGTERM', 'SIGQUIT' ]
            @logger.warn Rainbow("[Scheduler:#{@pid}] Received interrupt, terminating scheduler..").yellow
            reschedule_running_jobs
            break
          end
        end
      end
    end

    ##
    # Reschedules currently running jobs.
    #
    # @return [nil]
    def reschedule_running_jobs
      @job_class.running.each do |job|
        begin
          Process.kill :QUIT, job.pid if job.pid.present?
        rescue Errno::ESRCH, Errno::EPERM
        ensure
          job.schedule
        end
      end
    end

  end
end

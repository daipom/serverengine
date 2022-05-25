#
# ServerEngine
#
# Copyright (C) 2012-2013 Sadayuki Furuhashi
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
#
require 'serverengine/server'

module ServerEngine

  class MultiWorkerServer < Server
    def initialize(worker_module, load_config_proc={}, &block)
      @monitors = []
      @last_start_worker_time = 0

      super(worker_module, load_config_proc, &block)

      @stop_immediately_at_unrecoverable_exit = @config.fetch(:stop_immediately_at_unrecoverable_exit, false)
    end

    def stop(stop_graceful)
      super
      @monitors.each do |m|
        m.send_stop(stop_graceful) if m
      end
      nil
    end

    def restart(stop_graceful)
      super
      @monitors.each do |m|
        m.send_stop(stop_graceful) if m
      end
      nil
    end

    def reload
      super
      @monitors.each_with_index do |m|
        m.send_reload if m
      end
      nil
    end

    def run
      while true
        num_alive = keepalive_workers
        break if num_alive == 0
        wait_tick
      end
    end

    def scale_workers(n)
      @num_workers = n

      plus = n - @monitors.size
      if plus > 0
        @monitors.concat Array.new(plus, nil)
      end

      nil
    end

    def join_workers
      @monitors.each {|m|
        m.join if m
      }
    end

    private

    def reload_config
      super

      @start_worker_delay = @config[:start_worker_delay] || 0
      @start_worker_delay_rand = @config[:start_worker_delay_rand] || 0.2
      @restart_worker_interval = @config[:restart_worker_interval] || 0

      scale_workers(@config[:workers] || 1)

      nil
    end

    def wait_tick
      sleep 0.5
    end

    def keepalive_workers
      num_alive = 0

      @monitors.each_with_index do |m,wid|
        if m && m.alive?
          # alive
          num_alive += 1

        elsif m && m.respond_to?(:recoverable?) && !m.recoverable?
          # exited, with unrecoverable exit code
          if @stop_immediately_at_unrecoverable_exit
            stop(true) # graceful stop for workers
            # @stop is set by Server#stop
          end
          # server will stop when all workers exited in this state
          # the last status will be used for server/supervisor/daemon
          @stop_status = m.exitstatus if m.exitstatus

        elsif wid < @num_workers
          # scale up or reboot
          unless @stop
            if m
              restart_worker(wid)
            else
              start_new_worker(wid)
            end
            num_alive += 1
          end

        elsif m
          # scale down
          @monitors[wid] = nil
        end
      end

      return num_alive
    end

    def start_new_worker(wid)
      delayed_start_worker(wid)
    end

    def restart_worker(wid)
      m = @monitors[wid]

      if m.restarting?
        delayed_start_worker(wid) if m.delayed_restart_time_passed?
        return
      end

      if @restart_worker_interval > 0
        m.set_delayed_restart(@restart_worker_interval)
      else
        delayed_start_worker(wid)
      end
    end

    def delayed_start_worker(wid)
      if @start_worker_delay > 0
        delay = @start_worker_delay +
          Kernel.rand * @start_worker_delay * @start_worker_delay_rand -
          @start_worker_delay * @start_worker_delay_rand / 2

        now = Time.now.to_f

        wait = delay - (now - @last_start_worker_time)
        sleep wait if wait > 0

        @last_start_worker_time = now
      end

      @monitors[wid] = start_worker(wid)
    end
  end

  class WorkerMonitorBase
    def initialize
      @is_restarting = false
      @restart_delay = nil
      @restart_invoked_time = nil
    end

    def set_delayed_restart(delay)
      @is_restarting = true
      @restart_delay = delay
      @restart_invoked_time = Time.now.to_f
    end

    def restarting?
      @is_restarting
    end

    def delayed_restart_time_passed?
      return false unless restarting?

      passed_time = Time.now.to_f - @restart_invoked_time

      # Give up waiting because the time has changed or some other
      # unexpected situation may occur.
      return true if passed_time < 0

      return @restart_delay <= passed_time
    end

    def send_stop(stop_graceful)
      raise NotImplementedError, "Must override this"
    end

    def send_reload
      raise NotImplementedError, "Must override this"
    end

    def join
      raise NotImplementedError, "Must override this"
    end

    def alive?
      raise NotImplementedError, "Must override this"
    end

    def recoverable?
      raise NotImplementedError, "Must override this"
    end

    def exitstatus
      raise NotImplementedError, "Must override this"
    end
  end
end

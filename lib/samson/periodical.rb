# frozen_string_literal: true
# Inline Cron: use PERIODICAL environment variable
# Cron: Execute from commandline as cron via `rails runner 'Samson::Periodical.run_once :stop_expired_deploys'`
#
# Has global state so should never be autoloaded
require 'concurrent'

module Samson
  module Periodical
    TASK_DEFAULTS = {
      now: true, # see TimerTask, run at startup so we are in a consistent and clean state after a restart
      execution_interval: 60, # see TimerTask
      timeout_interval: 10, # see TimerTask
      active: false
    }.freeze

    class ExceptionReporter
      def initialize(task_name)
        @task_name = task_name
      end

      def update(time, _result, exception)
        return unless exception
        Rails.logger.error "(#{time})  with error #{exception}"
        Rails.logger.error exception.backtrace.join("\n")
        Airbrake.notify(exception, error_message: "Samson::Periodical #{@task_name} failed")
      end
    end

    class << self
      def register(name, description, options = {}, &block)
        registered[name] = TASK_DEFAULTS.
          merge(env_settings(name)).
          merge(block: block, description: description).
          merge(options)
      end

      # works with cron like setup for .run_once and in process execution via .run
      def overdue?(name, since)
        interval = registered.fetch(name).fetch(:execution_interval)
        since < (interval * 2).seconds.ago
      end

      def run
        registered.map do |name, config|
          next unless config.fetch(:active)
          with_consistent_start_time(config) do
            Concurrent::TimerTask.new(config) do
              ActiveRecord::Base.connection_pool.with_connection do
                execute_block(config)
              end
            end.with_observer(ExceptionReporter.new(name)).execute
          end
        end.compact
      end

      # method to test things out on console / testing
      # simulates timeout that Concurrent::TimerTask does
      def run_once(name)
        config = registered.fetch(name)
        Timeout.timeout(config.fetch(:timeout_interval)) do
          execute_block(config)
        end
      rescue
        ExceptionReporter.new(name).update(nil, nil, $!)
        raise
      end

      def interval(name)
        config = registered.fetch(name)
        config.fetch(:active) && config.fetch(:execution_interval)
      end

      private

      def with_consistent_start_time(config, &block)
        if config[:consistent_start_time]
          execution_interval = config.fetch(:execution_interval)
          time_to_next_execution = execution_interval - (Time.now.to_i % execution_interval)
          Concurrent::ScheduledTask.execute(time_to_next_execution, &block)
        else
          yield
        end
      end

      def execute_block(config)
        config.fetch(:block).call # needs a Proc
      end

      def env_settings(name)
        @env_settings ||= configs_from_string(ENV['PERIODICAL'])
        @env_settings[name] || {}
      end

      def configs_from_string(string)
        string.to_s.split(',').each_with_object({}) do |item, h|
          name, execution_interval = item.split(':', 2)
          config = {active: true}
          config[:execution_interval] = Integer(execution_interval) if execution_interval
          h[name.to_sym] = config
        end
      end

      def registered
        @registered ||= {}
      end
    end
  end
end

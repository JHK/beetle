module Beetle
  module RedisConfigurationAutoDetection #:nodoc:
    # auto detect redis master - will return nil if no valid master detected
    def auto_detect_master
      return nil unless master_and_slaves_reachable?
      redis_instances.find{|r| r.master? }
    end

    private

    def master_and_slaves_reachable?
      single_master_reachable? && redis_instances.select{|r| r.slave? }.size == redis_instances.size - 1
    end

    def single_master_reachable?
      redis_instances.select{|r| r.master? }.size == 1
    end
  end
end

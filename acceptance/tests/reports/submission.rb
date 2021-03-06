test_name "Report submission"

tag 'audit:high',
    'audit:integration'

if master.is_pe?
  require "time"

  def puppetdb
    hosts.detect { |h| h['roles'].include?('database') }
  end

  def sleep_until_queue_empty(timeout=60)
    metric = "org.apache.activemq:BrokerName=localhost,Type=Queue,Destination=com.puppetlabs.puppetdb.commands"
    queue_size = nil

    begin
      Timeout.timeout(timeout) do
        until queue_size == 0
          result = on(puppetdb, %Q{curl http://localhost:8080/v3/metrics/mbean/#{CGI.escape(metric)}})
          if md = /"?QueueSize"?\s*:\s*(\d+)/.match(result.stdout.chomp)
            queue_size = Integer(md[1])
          end
          sleep 1
        end
      end
    rescue Timeout::Error
      raise "Queue took longer than allowed #{timeout} seconds to empty"
    end
  end

  def query_last_report_time_on(agent)
    time_query_script = <<-EOS
      require "net/http"
      require "json"

      puppetdb_url = URI("http://localhost:8080/v3/reports")
      puppetdb_url.query = CGI.escape(%Q{query=["=","certname","#{agent}"]})
      result = Net::HTTP.get(puppetdb_url)
      json = JSON.load(result)
      puts json.first["receive-time"]
    EOS
    on(puppetdb, "#{master[:privatebindir]}/ruby -e '#{time_query_script}'").output.chomp
  end

  last_times = {}

  agents.each do |agent|
    last_times[agent] = query_last_report_time_on(agent)
  end

  with_puppet_running_on(master, {}) do
    agents.each do |agent|
      on(agent, puppet('agent', "-t"))

      sleep_until_queue_empty

      current_time = Time.parse(query_last_report_time_on(agent))
      last_time = Time.parse(last_times[agent])

      assert(current_time > last_time, "Most recent report time #{current_time} is not newer than last report time #{last_time}")
    end
  end

else

  testdir = create_tmpdir_for_user master, 'report_submission'

  teardown do
    on master, "rm -rf #{testdir}"
  end

  with_puppet_running_on(master, :main => { :reportdir => testdir, :reports => 'store' }) do
    agents.each do |agent|
      on(agent, puppet('agent', "-t"))

      on master, "grep -q #{agent.node_name} #{testdir}/*/*"
    end
  end

end

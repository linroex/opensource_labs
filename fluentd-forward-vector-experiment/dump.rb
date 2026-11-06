Signal.trap("TTIN") do
  Thread.new do
    File.open("/tmp/claude-0/-home-user-opensource-labs/89ee294e-aa15-5e48-94c3-1abcfc3c980e/scratchpad/lab/logs/threads.txt", "a") do |f|
      f.puts "===== #{Time.now} ====="
      Thread.list.each do |t|
        f.puts "--- #{t.name.inspect} status=#{t.status.inspect}"
        (t.backtrace || []).first(14).each { |l| f.puts "    #{l}" }
      end
    end
  end
end

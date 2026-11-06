require "msgpack"
require "socket"
# 每秒送 10 個 batch, 每個 batch 100 筆 x 10KB = 約 1MB  => 約 10MB/s
sock = TCPSocket.new("127.0.0.1", 24224)
payload = "x" * 10_000
loop do
  t0 = Time.now
  es = Array.new(100) { [Time.now.to_i, {"message" => payload}] }
  sock.write(["app.log", es].to_msgpack)
  sleep [0.1 - (Time.now - t0), 0].max
end

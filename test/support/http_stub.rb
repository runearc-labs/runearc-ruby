# frozen_string_literal: true

require "socket"

# A tiny local HTTP server for what the real API cannot be made to do on demand (answer 503,
# hang, drop the connection) and for receiving real webhook deliveries from the worker.
# The handler gets a Request and returns [status, headers, body], +:close+ to drop the
# connection or +:hang+ to never answer.
class HttpStub
  Request = Struct.new(:verb, :path, :headers, :body)

  attr_reader :requests

  def initialize(&handler)
    @handler = handler
    @requests = []
    @lock = Mutex.new
    @server = TCPServer.new("127.0.0.1", 0)
    @threads = []
    @closed = false
    @acceptor = Thread.new { accept_loop }
  end

  def url
    "http://127.0.0.1:#{@server.addr[1]}"
  end

  def stop
    @closed = true
    @server.close
    @acceptor.join
    @threads.each(&:kill)
  end

  private

  def accept_loop
    until @closed
      socket = @server.accept
      @threads << Thread.new { serve(socket) }
    end
  rescue IOError, Errno::EBADF
    nil
  end

  def serve(socket)
    request = read_request(socket)
    @lock.synchronize { @requests << request }
    answer = @handler.call(request)
    case answer
    when :close then nil
    when :hang then sleep
    else respond(socket, *answer)
    end
  rescue IOError, SystemCallError
    nil
  ensure
    socket.close unless socket.closed?
  end

  def read_request(socket)
    line = socket.gets
    method, path = line.split
    headers = {}
    while (header = socket.gets) && header != "\r\n"
      name, value = header.split(":", 2)
      headers[name.downcase] = value.strip
    end
    body = socket.read(headers.fetch("content-length", "0").to_i)
    Request.new(method, path, headers, body)
  end

  def respond(socket, status, headers, body)
    head = { "content-length" => body.bytesize.to_s, "connection" => "close" }.merge(headers)
    socket.write("HTTP/1.1 #{status} Status\r\n#{head.map { |k, v| "#{k}: #{v}\r\n" }.join}\r\n#{body}")
  end
end

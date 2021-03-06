require 'arachni/rpc/server/dispatcher'
require 'ostruct'

class ProcessHelper
    include Singleton

    def initialize
        @pids        = []
        @dispatchers = {}
    end

    def start_dispatcher( opts = {} )
        opts = Arachni::Options.to_h.merge( opts )
        opts['pool_size'] = 1

        opts['rpc_address'] ||= 'localhost'
        opts['rpc_port']    ||= generate_port

        pid = fork_em {
            Arachni::RPC::Server::Dispatcher.new( Arachni::Options.merge!( opts ) )
        }

        url = "#{opts['rpc_address']}:#{opts['rpc_port']}"

        d_opts = OpenStruct.new
        d_opts.max_retries = 0

        client = Arachni::RPC::Client::Dispatcher.new( d_opts, url )
        begin
            Timeout.timeout( 10 ) {
                while sleep( 0.1 )
                    begin
                        client.alive?
                        break
                    rescue
                    end
                end
            }
        rescue Timeout::Error
            fail "Dispatcher '#{url}' never started!"
            return
        end

        @dispatchers[url] = { pid: pid, client: client }

        client
    end

    def generate_port
        loop do
            port = 5555 + rand( 9999 )
            begin
                socket = Socket.new( :INET, :STREAM, 0 )
                socket.bind( Addrinfo.tcp( "127.0.0.1", port ) )
                socket.close
                return port
            rescue Errno::EADDRINUSE => e
            end
        end
    end

    def kill_dispatcher( url_or_model )
        url = url_or_model.is_a?( String ) ? url_or_model : url_or_model.url
        fail "There's no Dispatcher with URL: #{url}" if !@dispatchers[url]

        # Kill all of the Dispatcher's Instances.
        @dispatchers[url][:client].stats['consumed_pids'].each do |p|
            kill p
        end

        # Kill the Dispatcher.
        kill @dispatchers[url][:pid]
        @dispatchers.delete( url )

        nil
    end

    def killall_dispatchers
        @dispatchers.keys.each { |u| kill_dispatcher u }
    end

    def kill( pid )
        begin
            10.times { Process.kill( 'KILL', pid ) }
            return false
        rescue Errno::ESRCH
            @pids.delete pid
            return true
        end
    end

    def killall
        killall_dispatchers

        @pids.each { |p| kill p }
    end

    def fork_em( *args, &b )
        wrap = proc {
            $stdout.reopen( '/dev/null', 'w' )
            $stderr.reopen( '/dev/null', 'w' )
            b.call
        }

        @pids << (p = ::EM.fork_reactor( *args, &wrap ))
        Process.detach( p )
        p
    end

    def self.method_missing( sym, *args, &block )
        if instance.respond_to?( sym )
            instance.send( sym, *args, &block )
        elsif
        super( sym, *args, &block )
        end
    end

    def self.respond_to?( m )
        super( m ) || instance.respond_to?( m )
    end

end

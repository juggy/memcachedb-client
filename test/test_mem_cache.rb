# encoding: utf-8
require 'logger'
require 'stringio'
require 'test/unit'
require 'rubygems'
begin
  gem 'flexmock'
  require 'flexmock/test_unit'
rescue LoadError => e
  puts "Some tests require flexmock, please run `gem install flexmock`"
end

Thread.abort_on_exception = true
$TESTING = true

require File.dirname(__FILE__) + '/../lib/memcachedb' if not defined?(MemCacheDb)

class MemCacheDb

  attr_writer :namespace
  attr_writer :autofix_keys

end

class FakeSocket

  attr_reader :written, :data

  def initialize
    @written = StringIO.new
    @data = StringIO.new
  end

  def write(data)
    @written.write data
  end

  def gets
    @data.gets || 'STORED\n\r'
  end

  def read(arg)
    @data.read arg
  end

end

class Test::Unit::TestCase
  def requirement(bool, msg)
    if bool
      yield
    else
      puts msg
      assert true
    end
  end

  def memcached_running?
    TCPSocket.new('localhost', 11211) rescue false
  end

  def xprofile(name, &block)
    a = Time.now
    block.call
    Time.now - a
  end

  def profile(name, &block)
    require 'ruby-prof'
    a = Time.now
    result = RubyProf.profile(&block)
    time = Time.now - a
    printer = RubyProf::GraphHtmlPrinter.new(result)
    File.open("#{name}.html", 'w') do |f|
      printer.print(f, :min_percent=>1)
    end
    time
  end

end

class FakeGroup
   attr_reader :weight
   attr_reader :servers
   attr_reader :name
   
   def initialize(server = FakeServer.new, name = nil)
     @server = server
     @servers = []
     @servers << server
     @weight = 1
     @name = name || (server.host.to_s + server.port.to_s)
   end
   
   def alive?
    master.alive?
   end
   
   def master
     @server
   end
   
   def next_slave
     @server
   end
end

class FakeServer

  attr_accessor :host, :port, :socket, :weight, :multithread, :status

  def initialize(socket = nil)
    @closed = false
    @host = 'example.com'
    @port = 11211
    @socket = socket || FakeSocket.new
    @weight = 1
    @multithread = true
    @status = "CONNECTED"
  end

  def close
    # begin
    #   raise "Already closed"
    # rescue => e
    #   puts e.backtrace.join("\n")
    # end
    @closed = true
    @socket = nil
    @status = "NOT CONNECTED"
  end

  def alive?
    # puts "I'm #{@closed ? 'dead' : 'alive'}"
    !@closed
  end

end

class TestMemCache < Test::Unit::TestCase

  def setup
    @cache = MemCacheDb.new( {}, {:namespace => 'my_namespace'})
  end

  def util_setup_fake_server
    server = FakeServer.new
    server.socket.data.write "VALUE my_namespace:key 0 14\r\n"
    server.socket.data.write "\004\b\"\0170123456789\r\n"
    server.socket.data.write "END\r\n"
    server.socket.data.rewind

    group = FakeGroup.new(server)
    @cache.groups = []
    @cache.groups << group

    return server
  end


  def test_add
    server = FakeServer.new
    server.socket.data.write "STORED\r\n"
    server.socket.data.rewind

    group = FakeGroup.new(server)
    @cache.groups = []
    @cache.groups << group

    @cache.add 'key', 'value'

    dumped = Marshal.dump('value')

    expected = "add my_namespace:key 0 0 #{dumped.length}\r\n#{dumped}\r\n"
    assert_equal expected, server.socket.written.string
  end


  def test_performance
    requirement(memcached_running?, 'A real memcached server must be running for performance testing') do

      cache = MemCacheDb.new({:servers=>['localhost:11211',"localhost:11212"]})
      cache.add('a', 1, 120)
      with = xprofile 'get' do
        1000.times do
          cache.get('a')
        end
      end
      puts ''
      puts "1000 gets with socket timeout: #{with} sec"

      cache = MemCacheDb.new([{:servers=>['localhost:11211',"localhost:11212"]}], :timeout => nil)
      cache.add('a', 1, 120)
      without = xprofile 'get' do
        1000.times do
          cache.get('a')
        end
      end
      puts "1000 gets without socket timeout: #{without} sec"
    end
  end

  
  def test_get_multi_with_server_failure
    @cache = MemCacheDb.new({:server=>'localhost:1'}, {:namespace => 'my_namespace', :logger=>nil})
    s1 = FakeServer.new
    s2 = FakeServer.new
    
    g1 = FakeGroup.new(s1, "1")      
    g2 = FakeGroup.new(s2, "2")

    # Write two messages to the socket to test failover
    s1.socket.data.write "VALUE my_namespace:a 0 14\r\n\004\b\"\0170123456789\r\nEND\r\n"
    s1.socket.data.rewind
    s2.socket.data.write "bogus response\r\nbogus response\r\n"
    s2.socket.data.rewind

    @cache.groups = [g1, g2]

    assert s1.alive?
    assert s2.alive?
    # a maps to s1, the rest map to s2
    value = @cache.get_multi(['foo', 'bar', 'a', 'b', 'c'])
    assert_equal({'a'=>'0123456789'}, value)
    assert s1.alive?
    assert !s2.alive?
  end

  
  def test_consistent_hashing
    requirement(self.respond_to?(:flexmock), 'Flexmock is required to run this test') do

      flexmock(MemCacheDb::Server).new_instances.should_receive(:alive?).and_return(true)

      # Setup a continuum of two servers
      @cache.groups = [FakeGroup.new(FakeServer.new, "1"), FakeGroup.new(FakeServer.new, "2"), FakeGroup.new(FakeServer.new, "3")]

      keys = []
      1000.times do |idx|
        keys << idx.to_s
      end

      before_continuum = keys.map {|key| @cache.get_group_for_key(key) }

      @cache.groups =  [FakeGroup.new(FakeServer.new, "1"), FakeGroup.new(FakeServer.new, "2"), FakeGroup.new(FakeServer.new, "3"), FakeGroup.new(FakeServer.new, "4")]

      after_continuum = keys.map {|key| @cache.get_group_for_key(key) }

      same_count = before_continuum.zip(after_continuum).find_all {|a| a[0].name == a[1].name }.size

      # With continuum, we should see about 75% of the keys map to the same server
      # With modulo, we would see about 25%.
      assert same_count > 700
    end
  end
  
  def test_cache_get_with_failover
    @cache = MemCacheDb.new 'localhost:1', :namespace => 'my_namespace', :logger => nil#Logger.new(STDOUT)
    s1 = FakeServer.new
    s2 = FakeServer.new
    
    g1 = FakeGroup.new(s1)      
    g2 = FakeGroup.new(s2)

    # Write two messages to the socket to test failover
    s1.socket.data.write "VALUE foo 0 14\r\n\004\b\"\0170123456789\r\n"
    s1.socket.data.rewind
    s2.socket.data.write "bogus response\r\nbogus response\r\n"
    s2.socket.data.rewind

    @cache.instance_variable_set(:@failover, true)
    @cache.groups = [g1, g2]

    assert s1.alive?
    assert s2.alive?
    @cache.get('foo')
    assert s1.alive?
    assert !s2.alive?
  end
  
  def test_cache_get_without_failover
     s1 = FakeServer.new
     s2 = FakeServer.new

     g1 = FakeGroup.new(s1)      
     g2 = FakeGroup.new(s2)

     s1.socket.data.write "VALUE foo 0 14\r\n\004\b\"\0170123456789\r\n"
     s1.socket.data.rewind
     s2.socket.data.write "bogus response\r\nbogus response\r\n"
     s2.socket.data.rewind

     @cache.instance_variable_set(:@failover, false)
     @cache.groups = [g1, g2]

     assert s1.alive?
     assert s2.alive?
     e = assert_raise MemCacheDb::MemCacheDbError do
       @cache.get('foo')
     end
     assert s1.alive?
     assert !s2.alive?

     assert_equal "No servers available", e.message
   end

   def test_cache_get
     server = util_setup_fake_server

     assert_equal "\004\b\"\0170123456789",
                  @cache.cache_get(server, 'my_namespace:key')

     assert_equal "get my_namespace:key\r\n",
                  server.socket.written.string
   end

   def test_cache_get_EOF
     server = util_setup_fake_server
     server.socket.data.string = ''

     e = assert_raise IndexError do
       @cache.cache_get server, 'my_namespace:key'
     end

     assert_equal "No connection to server (NOT CONNECTED)", e.message
   end

   def test_cache_get_bad_state
     server = FakeServer.new

     # Write two messages to the socket to test failover
     server.socket.data.write "bogus response\r\nbogus response\r\n"
     server.socket.data.rewind

    group = FakeGroup.new(server)
     @cache.groups = []
     @cache.groups << group

     e = assert_raise IndexError do
       @cache.cache_get(server, 'my_namespace:key')
     end

     assert_match(/#{Regexp.quote 'No connection to server (NOT CONNECTED)'}/, e.message)

     assert !server.alive?
   end

   def test_cache_get_miss
     socket = FakeSocket.new
     socket.data.write "END\r\n"
     socket.data.rewind
     server = FakeServer.new socket

     assert_equal nil, @cache.cache_get(server, 'my_namespace:key')

     assert_equal "get my_namespace:key\r\n",
                  socket.written.string
   end

   def test_cache_get_multi
     server = util_setup_fake_server
     server.socket.data.write "VALUE foo 0 7\r\n"
     server.socket.data.write "\004\b\"\bfoo\r\n"
     server.socket.data.write "VALUE bar 0 7\r\n"
     server.socket.data.write "\004\b\"\bbar\r\n"
     server.socket.data.write "END\r\n"
     server.socket.data.rewind

     result = @cache.cache_get_multi server, 'foo bar baz'

     assert_equal 2, result.length
     assert_equal "\004\b\"\bfoo", result['foo']
     assert_equal "\004\b\"\bbar", result['bar']
   end

   def test_cache_get_multi_EOF
     server = util_setup_fake_server
     server.socket.data.string = ''

     e = assert_raise IndexError do
       @cache.cache_get_multi server, 'my_namespace:key'
     end

     assert_equal "No connection to server (NOT CONNECTED)", e.message
   end

   def test_cache_get_multi_bad_state
     server = FakeServer.new

     # Write two messages to the socket to test failover
     server.socket.data.write "bogus response\r\nbogus response\r\n"
     server.socket.data.rewind

    group = FakeGroup.new(server)
     @cache.groups = []
     @cache.groups << group

     e = assert_raise IndexError do
       @cache.cache_get_multi server, 'my_namespace:key'
     end

     assert_match(/#{Regexp.quote 'No connection to server (NOT CONNECTED)'}/, e.message)

     assert !server.alive?
   end
   
   def test_multithread_error
      server = FakeServer.new
      server.multithread = false

      @cache = MemCacheDb.new(['localhost:1'], :multithread => false)

      server.socket.data.write "bogus response\r\nbogus response\r\n"
      server.socket.data.rewind

     group = FakeGroup.new(server)
      @cache.groups = []
      @cache.groups << group

      assert_nothing_raised do
        @cache.set 'a', 1
      end

      passed = true
      Thread.new do
        begin
          @cache.set 'b', 2
          passed = false
        rescue MemCacheDb::MemCacheDbError => me
          passed = me.message =~ /multiple threads/
        end
      end
      assert passed
    end

    def test_initialize
      cache = MemCacheDb.new ([], {:namespace => 'my_namespace', :readonly => true})

      assert_equal 'my_namespace', cache.namespace
      assert_equal true, cache.readonly?
      assert_equal true, cache.groups.empty?
    end

    def test_initialize_compatible
      cache = MemCacheDb.new ([:servers=>['localhost:11211', 'localhost:11212']],
              :namespace => 'my_namespace', :readonly => true)

      assert_equal 'my_namespace', cache.namespace
      assert_equal true, cache.readonly?
      assert_equal false, cache.groups.empty?
    end

    def test_initialize_compatible_no_hash
      cache = MemCacheDb.new (:servers=>['localhost:11211', 'localhost:11212'])

      assert_equal nil, cache.namespace
      assert_equal false, cache.readonly?
      assert_equal false, cache.groups.empty?
    end

    def test_initialize_compatible_bad_arg
      e = assert_raise ArgumentError do
        cache = MemCacheDb.new Object.new
      end

      assert_equal 'first argument must be Array, Hash', e.message
    end
    
    def test_initialize_too_many_args
      assert_raises ArgumentError do
        MemCacheDb.new 1, 2, 3
      end
    end
      
    
    def test_initialize_multiple_servers
      cache = MemCacheDb.new([{:servers=>['localhost:11211', 'localhost:11212']}, {:servers=>['localhost:11211', 'localhost:11212']}],
                           {:namespace => 'my_namespace', :readonly => true})

      assert_equal 'my_namespace', cache.namespace
      assert_equal true, cache.readonly?
      assert_equal false, cache.groups.empty?
      assert !cache.instance_variable_get(:@continuum).empty?
    end

    def test_decr
       server = FakeServer.new
       server.socket.data.write "5\r\n"
       server.socket.data.rewind

      group = FakeGroup.new(server)
       @cache.groups = []
       @cache.groups << group

       value = @cache.decr 'key'

       assert_equal "decr my_namespace:key 1\r\n",
                    @cache.groups.first.servers.first.socket.written.string

       assert_equal 5, value
     end

     def test_decr_not_found
       server = FakeServer.new
       server.socket.data.write "NOT_FOUND\r\n"
       server.socket.data.rewind

      group = FakeGroup.new(server)
       @cache.groups = []
       @cache.groups << group

       value = @cache.decr 'key'

       assert_equal "decr my_namespace:key 1\r\n",
                    @cache.groups.first.servers.first.socket.written.string

       assert_equal nil, value
     end

     def test_decr_space_padding
       server = FakeServer.new
       server.socket.data.write "5 \r\n"
       server.socket.data.rewind

      group = FakeGroup.new(server)
       @cache.groups = []
       @cache.groups << group

       value = @cache.decr 'key'

       assert_equal "decr my_namespace:key 1\r\n",
                    @cache.groups.first.servers.first.socket.written.string

       assert_equal 5, value
     end

     def test_get
       util_setup_fake_server

       value = @cache.get 'key'

       assert_equal "get my_namespace:key\r\n",
                    @cache.groups.first.servers.first.socket.written.string

       assert_equal '0123456789', value
     end
    
    
     def test_fetch_without_a_block
       server = FakeServer.new
       server.socket.data.write "END\r\n"
       server.socket.data.rewind

       group = FakeGroup.new(server)
       @cache.groups = [group]

       flexmock(@cache).should_receive(:get).with('key', false).and_return(nil)

       value = @cache.fetch('key', 1)
       assert_equal nil, value
     end

     def test_fetch_miss
       server = FakeServer.new
       server.socket.data.write "END\r\n"
       server.socket.data.rewind

       group = FakeGroup.new(server)
       @cache.groups = [group]

       flexmock(@cache).should_receive(:get).with('key', false).and_return(nil)
       flexmock(@cache).should_receive(:add).with('key', 'value', 1, false)

       value = @cache.fetch('key', 1) { 'value' }

       assert_equal 'value', value
     end

     def test_fetch_hit
       server = FakeServer.new
       server.socket.data.write "END\r\n"
       server.socket.data.rewind

       group = FakeGroup.new(server)
       @cache.groups = [group]

       flexmock(@cache).should_receive(:get).with('key', false).and_return('value')
       flexmock(@cache).should_receive(:add).never

       value = @cache.fetch('key', 1) { raise 'Should not be called.' }

       assert_equal 'value', value
     end

     def test_get_bad_key
       util_setup_fake_server
       assert_raise ArgumentError do @cache.get 'k y' end

       util_setup_fake_server
       assert_raise ArgumentError do @cache.get 'k' * 250 end
     end

     def test_get_cache_get_IOError
       socket = Object.new
       def socket.write(arg) raise IOError, 'some io error'; end
       server = FakeServer.new socket

      group = FakeGroup.new(server)
       @cache.groups = []
       @cache.groups << group

       e = assert_raise MemCacheDb::MemCacheDbError do
         @cache.get 'my_namespace:key'
       end

       assert_equal 'some io error', e.message
     end
     
     
     def test_get_cache_get_SystemCallError
       socket = Object.new
       def socket.write(arg) raise SystemCallError, 'some syscall error'; end
       server = FakeServer.new socket

      group = FakeGroup.new(server)
       @cache.groups = []
       @cache.groups << group

       e = assert_raise MemCacheDb::MemCacheDbError do
         @cache.get 'my_namespace:key'
       end

       assert_equal 'unknown error - some syscall error', e.message
     end

     def test_get_no_connection
       e = assert_raise MemCacheDb::MemCacheDbError do
         @cache.groups = [:servers=>'localhost:1']
       end

       assert_match(/^No Master Server found/, e.message)
     end

     def test_get_no_servers
       @cache.groups = []
       e = assert_raise MemCacheDb::MemCacheDbError do
         @cache.get 'key'
       end

       assert_equal 'No active servers', e.message
     end

     def test_get_multi
        server = FakeServer.new
        server.socket.data.write "VALUE my_namespace:key 0 14\r\n"
        server.socket.data.write "\004\b\"\0170123456789\r\n"
        server.socket.data.write "VALUE my_namespace:keyb 0 14\r\n"
        server.socket.data.write "\004\b\"\0179876543210\r\n"
        server.socket.data.write "END\r\n"
        server.socket.data.rewind

       group = FakeGroup.new(server)
        @cache.groups = []
        @cache.groups << group

        values = @cache.get_multi 'key', 'keyb'

        assert_equal "get my_namespace:key my_namespace:keyb\r\n",
                     server.socket.written.string

        expected = { 'key' => '0123456789', 'keyb' => '9876543210' }

        assert_equal expected.sort, values.sort
      end

      def test_get_raw
        server = FakeServer.new
        server.socket.data.write "VALUE my_namespace:key 0 10\r\n"
        server.socket.data.write "0123456789\r\n"
        server.socket.data.write "END\r\n"
        server.socket.data.rewind

       group = FakeGroup.new(server)
        @cache.groups = []
        @cache.groups << group


        value = @cache.get 'key', true

        assert_equal "get my_namespace:key\r\n",
                     @cache.groups.first.servers.first.socket.written.string

        assert_equal '0123456789', value
      end

      def test_get_server_for_key_no_servers
        @cache.groups = []

        e = assert_raise MemCacheDb::MemCacheDbError do
          @cache.get_group_for_key 'key'
        end

        assert_equal 'No servers available', e.message
      end

      def test_get_server_for_key_spaces
        e = assert_raise ArgumentError do
          @cache.get_group_for_key 'space key'
        end
        assert_equal 'illegal character in key "space key"', e.message
      end

    
      def test_get_server_for_key_length
        @cache.groups = [FakeGroup.new]
        @cache.get_group_for_key 'x' * 250
        long_key = 'x' * 251
        e = assert_raise ArgumentError do
          @cache.get_group_for_key long_key
        end
        assert_equal "key too long #{long_key.inspect}", e.message
      end

      def test_incr
        server = FakeServer.new
        server.socket.data.write "5\r\n"
        server.socket.data.rewind

       group = FakeGroup.new(server)
        @cache.groups = []
        @cache.groups << group

        value = @cache.incr 'key'

        assert_equal "incr my_namespace:key 1\r\n",
                     @cache.groups.first.servers.first.socket.written.string

        assert_equal 5, value
      end

      def test_incr_not_found
        server = FakeServer.new
        server.socket.data.write "NOT_FOUND\r\n"
        server.socket.data.rewind

       group = FakeGroup.new(server)
        @cache.groups = []
        @cache.groups << group

        value = @cache.incr 'key'

        assert_equal "incr my_namespace:key 1\r\n",
                     @cache.groups.first.servers.first.socket.written.string

        assert_equal nil, value
      end

      def test_incr_space_padding
        server = FakeServer.new
        server.socket.data.write "5 \r\n"
        server.socket.data.rewind

       group = FakeGroup.new(server)
        @cache.groups = []
        @cache.groups << group

        value = @cache.incr 'key'

        assert_equal "incr my_namespace:key 1\r\n",
                     @cache.groups.first.servers.first.socket.written.string

        assert_equal 5, value
      end
      
      def test_make_cache_key
         assert_equal 'my_namespace:key', @cache.make_cache_key('key')
         @cache.namespace = nil
         assert_equal 'key', @cache.make_cache_key('key')
       end

       def test_make_cache_key_without_autofix
         @cache.autofix_keys = false

         key = "keys with more than two hundred and fifty characters can cause problems, because they get truncated and start colliding with each other. It's not a common occurrence, but when it happens is very hard to debug. the autofix option takes care of that for you"
         hash = Digest::SHA1.hexdigest(key)
         @cache.namespace = nil
         assert_equal key, @cache.make_cache_key(key)
       end

       def test_make_cache_key_with_autofix
         @cache.autofix_keys = true

         @cache.namespace = "my_namespace"
         assert_equal 'my_namespace:key', @cache.make_cache_key('key')
         @cache.namespace = nil
         assert_equal 'key', @cache.make_cache_key('key')

         key = "keys with more than two hundred and fifty characters can cause problems, because they get truncated and start colliding with each other. It's not a common occurrence, but when it happens is very hard to debug. the autofix option takes care of that for you"
         hash = Digest::SHA1.hexdigest(key)
         @cache.namespace = "my_namespace"
         assert_equal "my_namespace:#{hash}-autofixed", @cache.make_cache_key(key)
         @cache.namespace = nil
         assert_equal "#{hash}-autofixed", @cache.make_cache_key(key)

         key = "a short key with spaces"
         hash = Digest::SHA1.hexdigest(key)
         @cache.namespace = "my_namespace"
         assert_equal "my_namespace:#{hash}-autofixed", @cache.make_cache_key(key)
         @cache.namespace = nil
         assert_equal "#{hash}-autofixed", @cache.make_cache_key(key)

         # namespace + separator + key > 250
         key = 'k' * 240
         hash = Digest::SHA1.hexdigest(key)
         @cache.namespace = 'n' * 10
         assert_equal "#{@cache.namespace}:#{hash}-autofixed", @cache.make_cache_key(key)
       end

         def test_servers
           server = FakeServer.new
           group = FakeGroup.new(server)
           @cache.groups = []
           @cache.groups << group
           assert_equal [group], @cache.groups
         end

         def test_set
           server = FakeServer.new
           server.socket.data.write "STORED\r\n"
           server.socket.data.rewind
          group = FakeGroup.new(server)
           @cache.groups = []
           @cache.groups << group

           @cache.set 'key', 'value'

           dumped = Marshal.dump('value')
           expected = "set my_namespace:key 0 0 #{dumped.length}\r\n#{dumped}\r\n"
       #    expected = "set my_namespace:key 0 0 9\r\n\004\b\"\nvalue\r\n"
           assert_equal expected, server.socket.written.string
         end

         def test_set_expiry
           server = FakeServer.new
           server.socket.data.write "STORED\r\n"
           server.socket.data.rewind
          group = FakeGroup.new(server)
           @cache.groups = []
           @cache.groups << group

           @cache.set 'key', 'value', 5

           dumped = Marshal.dump('value')
           expected = "set my_namespace:key 0 5 #{dumped.length}\r\n#{dumped}\r\n"
           assert_equal expected, server.socket.written.string
         end

         def test_set_raw
           server = FakeServer.new
           server.socket.data.write "STORED\r\n"
           server.socket.data.rewind
          group = FakeGroup.new(server)
           @cache.groups = []
           @cache.groups << group

           @cache.set 'key', 'value', 0, true

           expected = "set my_namespace:key 0 0 5\r\nvalue\r\n"
           assert_equal expected, server.socket.written.string
         end

         def test_set_readonly
           cache = MemCacheDb.new( [FakeGroup.new], :readonly => true)

           e = assert_raise MemCacheDb::MemCacheDbError do
             cache.set 'key', 'value'
           end

           assert_equal 'Update of readonly cache', e.message
         end
         
         def test_check_size_on
            cache = MemCacheDb.new( [FakeGroup.new], :check_size => true)

            server = FakeServer.new
            server.socket.data.write "STORED\r\n"
            server.socket.data.rewind

            group = FakeGroup.new(server)
              cache.groups = []
              cache.groups << group

            e = assert_raise MemCacheDb::MemCacheDbError do
              cache.set 'key', 'v' * 1048577
            end

            assert_equal 'Value too large, MemCacheDbd can only store 1MB of data per key', e.message
          end

          def test_check_size_off
            cache = MemCacheDb.new([FakeGroup.new],  :check_size => false)

            server = FakeServer.new
            server.socket.data.write "STORED\r\n"
            server.socket.data.rewind

            group = FakeGroup.new(server)
              cache.groups = []
              cache.groups << group

            assert_nothing_raised do
              cache.set 'key', 'v' * 1048577
            end
          end

          def test_set_too_big
            server = FakeServer.new

            # Write two messages to the socket to test failover
            server.socket.data.write "SERVER_ERROR\r\nSERVER_ERROR object too large for cache\r\n"
            server.socket.data.rewind

           group = FakeGroup.new(server)
            @cache.groups = []
            @cache.groups << group

            e = assert_raise MemCacheDb::MemCacheDbError do
              @cache.set 'key', 'v'
            end

            assert_match(/object too large for cache/, e.message)
          end

          def test_prepend
            server = FakeServer.new
            server.socket.data.write "STORED\r\n"
            server.socket.data.rewind
           group = FakeGroup.new(server)
            @cache.groups = []
            @cache.groups << group

            @cache.prepend 'key', 'value'

            dumped = Marshal.dump('value')

            expected = "prepend my_namespace:key 0 0 5\r\nvalue\r\n"
            assert_equal expected, server.socket.written.string
          end

          def test_append
            server = FakeServer.new
            server.socket.data.write "STORED\r\n"
            server.socket.data.rewind
           group = FakeGroup.new(server)
            @cache.groups = []
            @cache.groups << group

            @cache.append 'key', 'value'

            expected = "append my_namespace:key 0 0 5\r\nvalue\r\n"
            assert_equal expected, server.socket.written.string
          end
         
          def test_replace
            server = FakeServer.new
            server.socket.data.write "STORED\r\n"
            server.socket.data.rewind
           group = FakeGroup.new(server)
            @cache.groups = []
            @cache.groups << group

            @cache.replace 'key', 'value', 150

            dumped = Marshal.dump('value')

            expected = "replace my_namespace:key 0 150 #{dumped.length}\r\n#{dumped}\r\n"
            assert_equal expected, server.socket.written.string
          end

          def test_add_exists
            server = FakeServer.new
            server.socket.data.write "NOT_STORED\r\n"
            server.socket.data.rewind
           group = FakeGroup.new(server)
            @cache.groups = []
            @cache.groups << group

            @cache.add 'key', 'value'

            dumped = Marshal.dump('value')
            expected = "add my_namespace:key 0 0 #{dumped.length}\r\n#{dumped}\r\n"
            assert_equal expected, server.socket.written.string
          end

          def test_add_expiry
            server = FakeServer.new
            server.socket.data.write "STORED\r\n"
            server.socket.data.rewind
           group = FakeGroup.new(server)
            @cache.groups = []
            @cache.groups << group

            @cache.add 'key', 'value', 5

            dumped = Marshal.dump('value')
            expected = "add my_namespace:key 0 5 #{dumped.length}\r\n#{dumped}\r\n"
            assert_equal expected, server.socket.written.string
          end

          def test_add_raw
            server = FakeServer.new
            server.socket.data.write "STORED\r\n"
            server.socket.data.rewind
           group = FakeGroup.new(server)
            @cache.groups = []
            @cache.groups << group

            @cache.add 'key', 'value', 0, true

            expected = "add my_namespace:key 0 0 5\r\nvalue\r\n"
            assert_equal expected, server.socket.written.string
          end

          def test_add_raw_int
            server = FakeServer.new
            server.socket.data.write "STORED\r\n"
            server.socket.data.rewind
           group = FakeGroup.new(server)
            @cache.groups = []
            @cache.groups << group

            @cache.add 'key', 12, 0, true

            expected = "add my_namespace:key 0 0 2\r\n12\r\n"
            assert_equal expected, server.socket.written.string
          end

          def test_add_readonly
            cache = MemCacheDb.new ([FakeGroup.new],:readonly => true)

            e = assert_raise MemCacheDb::MemCacheDbError do
              cache.add 'key', 'value'
            end

            assert_equal 'Update of readonly cache', e.message
          end

          def test_delete
            server = FakeServer.new
           group = FakeGroup.new(server)
            @cache.groups = []
            @cache.groups << group

            @cache.delete 'key'

            expected = "delete my_namespace:key\r\n"
            assert_equal expected, group.master.socket.written.string
          end

          def test_delete_with_expiry
            server = FakeServer.new
           group = FakeGroup.new(server)
            @cache.groups = []
            @cache.groups << group

            @cache.delete 'key', 300

            expected = "delete my_namespace:key\r\n"
            assert_equal expected, group.master.socket.written.string
          end




 def test_basic_threaded_operations_should_work
   cache = MemCacheDb.new ([FakeGroup.new], :multithread => true,
                        :namespace => 'my_namespace',
                        :readonly => false)

   server = FakeServer.new
   server.socket.data.write "STORED\r\n"
   server.socket.data.rewind

   group = FakeGroup.new(server)
     cache.groups = []
     cache.groups << group

   assert cache.multithread

   assert_nothing_raised do
     cache.set "test", "test value"
   end

   output = server.socket.written.string
   assert_match(/set my_namespace:test/, output)
   assert_match(/test value/, output)
 end

 def test_namespace_separator
   cache = MemCacheDb.new ( [FakeGroup.new], :namespace => 'ns', :namespace_separator => '')

   server = FakeServer.new
   server.socket.data.write "STORED\r\n"
   server.socket.data.rewind

   group = FakeGroup.new(server)
     cache.groups = []
     cache.groups << group

   assert_nothing_raised do
     cache.set "test", "test value"
   end

   output = server.socket.written.string
   assert_match(/set nstest/, output)
   assert_match(/test value/, output)
 end

 def test_basic_unthreaded_operations_should_work
   cache = MemCacheDb.new ( [FakeGroup.new], :multithread => false,
                        :namespace => 'my_namespace',
                        :readonly => false)

   server = FakeServer.new
   server.socket.data.write "STORED\r\n"
   server.socket.data.rewind

   group = FakeGroup.new(server)
     cache.groups = []
     cache.groups << group

   assert !cache.multithread

   assert_nothing_raised do
     cache.set "test", "test value"
   end

   output = server.socket.written.string
   assert_match(/set my_namespace:test/, output)
   assert_match(/test value/, output)
 end



 def util_setup_server(memcache, host, responses)
   server = MemCacheDb::Server.new memcache, host
   server.instance_variable_set :@sock, StringIO.new(responses)

  group = FakeGroup.new(server)
   @cache.groups = []
   @cache.groups << group

   return server
 end

 def test_crazy_multithreaded_access
   requirement(memcached_running?, 'A real memcached server must be running for performance testing') do

     # Use a null logger to verify logging doesn't blow up at runtime
     cache = MemCacheDb.new([{:servers=>['localhost:11211', 'localhost:11212']}], :logger => Logger.new('/dev/null'))
     workers = []



     # Have a bunch of threads perform a bunch of operations at the same time.
     # Verify the result of each operation to ensure the request and response
     # are not intermingled between threads.
     10.times do
       workers << Thread.new do
         100.times do
           cache.set('a', 9)
           cache.set('b', 11)
           cache.add('c', 10, 0, true)
           cache.set('d', 'a', 100, true)
           cache.set('e', 'x', 100, true)
           cache.set('f', 'zzz')
           cache.append('d', 'b')
           cache.prepend('e', 'y')
           assert_equal "NOT_STORED\r\n", cache.add('a', 11)
           assert_equal({ 'a' => 9, 'b' => 11 }, cache.get_multi(['a', 'b']))
           inc = cache.incr('c', 10)
           assert_equal 0, inc % 5
           assert inc > 14
           assert cache.decr('c', 5) > 14
           assert_equal 11, cache.get('b')
           d = cache.get('d', true)
           assert_match(/\Aab*\Z/, d)
           e = cache.get('e', true)
           assert_match(/\Ay*x\Z/, e)
         end
       end
     end

     workers.each { |w| w.join }
   end
 end
 def test_stats
   socket = FakeSocket.new
   socket.data.write "STAT pid 20188\r\nSTAT total_items 32\r\nSTAT version 1.2.3\r\nSTAT rusage_user 1:300\r\nSTAT dummy ok\r\nEND\r\n"
   socket.data.rewind
   server = FakeServer.new socket
   def server.host() 'localhost'; end
   def server.port() 11211; end

  group = FakeGroup.new(server)
   @cache.groups = []
   @cache.groups << group

   expected = {
     'localhost:11211' => {
       'pid' => 20188, 'total_items' => 32, 'version' => '1.2.3',
       'rusage_user' => 1.0003, 'dummy' => 'ok'
     }
   }
   assert_equal expected, @cache.stats

   assert_equal "stats\r\n", socket.written.string
 end
end


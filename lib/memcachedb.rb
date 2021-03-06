$TESTING = defined?($TESTING) && $TESTING

require 'socket'
require 'thread'
require 'zlib'
require 'yaml'
require 'digest/sha1'
require 'net/protocol'

begin
  # Try to use the SystemTimer gem instead of Ruby's timeout library
  # when running on something that looks like Ruby 1.8.x. See:
  #   http://ph7spot.com/articles/system_timer
  # We don't want to bother trying to load SystemTimer on jruby and
  # ruby 1.9+
  if defined?(JRUBY_VERSION) || (RUBY_VERSION >= '1.9')
    require 'timeout'
    MemCacheDbTimer = Timeout
  else
    require 'system_timer'
    MemCacheDbTimer = SystemTimer
  end
rescue LoadError => e
  puts "[MemCacheDb-client] Could not load SystemTimer gem, falling back to Ruby's slower/unsafe timeout library: #{e.message}"
  require 'timeout'
  MemCacheDbTimer = Timeout
end


##
# A Ruby client library for MemCacheDbd.
#

class MemCacheDb

  ##
  # The version of MemCacheDb you are using.

  VERSION = begin
    config = YAML.load(File.read(File.dirname(__FILE__) + '/../VERSION.yml'))
    "#{config[:major]}.#{config[:minor]}.#{config[:patch]}"
  end

  ##
  # Default options for the cache object.

  DEFAULT_OPTIONS = {
    :namespace    => nil,
    :readonly     => false,
    :multithread  => true,
    :failover     => true,
    :timeout      => 0.5,
    :logger       => nil,
    :no_reply     => false,
    :check_size   => true,
    :autofix_keys => false,
    :namespace_separator => ':',
  }

  ##
  # Default MemCacheDbd port.

  DEFAULT_PORT = 11211

  ##
  # Default MemCacheDbd server weight.

  DEFAULT_WEIGHT = 1

  ##
  # The namespace for this instance

  attr_reader :namespace

  ##
  # The multithread setting for this instance

  attr_reader :multithread

  ##
  # Whether to try to fix keys that are too long and will be truncated by
  # using their SHA1 hash instead.
  # The hash is only used on keys longer than 250 characters, or containing spaces,
  # to avoid impacting performance unnecesarily.
  #
  # In theory, your code should generate correct keys when calling MemCacheDb,
  # so it's your responsibility and you should try to fix this problem at its source.
  #
  # But if that's not possible, enable this option and MemCacheDb-client will give you a hand.

  attr_reader :autofix_keys

  ##
  # The servers this client talks to.  Play at your own peril.

  attr_reader :servers
  
  ##
  # The groups of servers that behaves in a master/slave configuration
  attr_reader :groups

  ##
  # Socket timeout limit with this client, defaults to 0.5 sec.
  # Set to nil to disable timeouts.

  attr_reader :timeout

  ##
  # Should the client try to failover to another server if the
  # first server is down?  Defaults to true.

  attr_reader :failover

  ##
  # Log debug/info/warn/error to the given Logger, defaults to nil.

  attr_reader :logger

  ##
  # Don't send or look for a reply from the MemCacheDbd server for write operations.
  # Please note this feature only works in MemCacheDbd 1.2.5 and later.  Earlier
  # versions will reply with "ERROR".
  attr_reader :no_reply

  ##
  # Accepts a list of +servers+ and a list of +opts+.  +servers+ may be
  # omitted.  See +servers=+ for acceptable server list arguments.
  #
  # Valid options for +opts+ are:
  #
  #   [:namespace]    Prepends this value to all keys added or retrieved.
  #   [:readonly]     Raises an exception on cache writes when true.
  #   [:multithread]  Wraps cache access in a Mutex for thread safety. Defaults to true.
  #   [:failover]     Should the client try to failover to another server if the
  #                   first server is down?  Defaults to true.
  #   [:timeout]      Time to use as the socket read timeout.  Defaults to 0.5 sec,
  #                   set to nil to disable timeouts.
  #   [:logger]       Logger to use for info/debug output, defaults to nil
  #   [:no_reply]     Don't bother looking for a reply for write operations (i.e. they
  #                   become 'fire and forget'), MemCacheDbd 1.2.5 and later only, speeds up
  #                   set/add/delete/incr/decr significantly.
  #   [:check_size]   Raises a MemCacheDbError if the value to be set is greater than 1 MB, which
  #                   is the maximum key size for the standard MemCacheDbd server.  Defaults to true.
  #   [:autofix_keys] If a key is longer than 250 characters or contains spaces,
  #                   use an SHA1 hash instead, to prevent collisions on truncated keys.
  # Other options are ignored.

  def initialize(*args)
    groups = []
    opts = {}

    case args.length
    when 0 then # NOP
    when 1 then
      arg = args.shift
      case arg
      when Hash   then groups << arg
      when Array  then groups = arg
      else raise ArgumentError, 'first argument must be Array, Hash'
      end
    when 2 then
      groups, opts = args
    else
      raise ArgumentError, "wrong number of arguments (#{args.length} for 2)"
    end

    opts = DEFAULT_OPTIONS.merge opts
    @namespace    = opts[:namespace]
    @readonly     = opts[:readonly]
    @multithread  = opts[:multithread]
    @autofix_keys = opts[:autofix_keys]
    @timeout      = opts[:timeout]
    @failover     = opts[:failover]
    @logger       = opts[:logger]
    @no_reply     = opts[:no_reply]
    @check_size   = opts[:check_size]
    @namespace_separator = opts[:namespace_separator]
    @mutex        = Mutex.new if @multithread

    logger.info { "MemCacheDb-client #{VERSION} #{Array(groups).inspect}" } if logger

    Thread.current[:memcachedb_client] = self.object_id if !@multithread
    self.groups = groups
  end

  ##
  # Returns a string representation of the cache object.

  def inspect
    "<MemCacheDb: %d groups, ns: %p, ro: %p>" %
      [@groups.length, @namespace, @readonly]
  end

  ##
  # Returns whether there is at least one active server for the object.

  def active?
    not groups.empty?
  end

  ##
  # Returns whether or not the cache object was created read only.

  def readonly?
    @readonly
  end

  ##
  # Set the groups that the requests will be distributed between.  Entries
  # must be a hash in the form {:servers=>[...], :weight=>1}  or
  # MemCacheDb::Group objects.
  #

  def groups=(groups)
    @groups = Array(groups).collect do |group|
      case group
      when Hash
        servers = create_servers(group[:servers])
        Group.new(self, servers, group[:name], group[:weight])
      else
        group
      end
    end
    @continuum = create_continuum_for(@groups) if @groups.size > 1

    @groups
  end
  
  
  def create_servers(servers)
    Array(servers).collect do |server|
      case server
      when String
        host, port, weight = server.split ':', 3
        port ||= DEFAULT_PORT
        weight ||= DEFAULT_WEIGHT
        Server.new self, host, port, weight
      else
        server
      end
    end
  end
  
  ##
  # Decrements the value for +key+ by +amount+ and returns the new value.
  # +key+ must already exist.  If +key+ is not an integer, it is assumed to be
  # 0.  +key+ can not be decremented below 0.

  def decr(key, amount = 1)
    raise MemCacheDbError, "Update of readonly cache" if @readonly
    with_server(key) do |server, cache_key|
      cache_decr server, cache_key, amount
    end
  rescue TypeError => err
    handle_error nil, err
  end

  ##
  # Retrieves +key+ from MemCacheDb.  If +raw+ is false, the value will be
  # unmarshalled.

  def get(key, raw = false)
    with_server(key, true) do |server, cache_key|
      logger.debug { "get #{key} from #{server.inspect}" } if logger
      value = cache_get server, cache_key
      return nil if value.nil?
      value = Marshal.load value unless raw
      return value
    end
  rescue TypeError => err
    handle_error nil, err
  end

  ##
  # Performs a +get+ with the given +key+.  If
  # the value does not exist and a block was given,
  # the block will be called and the result saved via +add+.
  #
  # If you do not provide a block, using this
  # method is the same as using +get+.
  #
  def fetch(key, expiry = 0, raw = false)
    value = get(key, raw)

    if value.nil? && block_given?
      value = yield
      add(key, value, expiry, raw)
    end

    value
  end

  ##
  # Retrieves multiple values from MemCacheDbd in parallel, if possible.
  #
  # The MemCacheDbd protocol supports the ability to retrieve multiple
  # keys in a single request.  Pass in an array of keys to this method
  # and it will:
  #
  # 1. map the key to the appropriate MemCacheDbd server
  # 2. send a single request to each server that has one or more key values
  #
  # Returns a hash of values.
  #
  #   cache["a"] = 1
  #   cache["b"] = 2
  #   cache.get_multi "a", "b" # => { "a" => 1, "b" => 2 }
  #
  # Note that get_multi assumes the values are marshalled.

  def get_multi(*keys)
    raise MemCacheDbError, 'No active servers' unless active?

    keys.flatten!
    key_count = keys.length
    cache_keys = {}
    server_keys = Hash.new { |h,k| h[k] = [] }

    # map keys to servers
    keys.each do |key|
      server, cache_key = request_setup key, true
      cache_keys[cache_key] = key
      server_keys[server] << cache_key
    end

    results = {}
    server_keys.each do |server, keys_for_server|
      keys_for_server_str = keys_for_server.join ' '
      begin
        values = cache_get_multi server, keys_for_server_str
        values.each do |key, value|
          results[cache_keys[key]] = Marshal.load value
        end
      rescue IndexError => e
        # Ignore this server and try the others
        logger.warn { "Unable to retrieve #{keys_for_server.size} elements from #{server.inspect}: #{e.message}"} if logger
      end
    end

    return results
  rescue TypeError => err
    handle_error nil, err
  end

  ##
  # Increments the value for +key+ by +amount+ and returns the new value.
  # +key+ must already exist.  If +key+ is not an integer, it is assumed to be
  # 0.

  def incr(key, amount = 1)
    raise MemCacheDbError, "Update of readonly cache" if @readonly
    with_server(key) do |server, cache_key|
      cache_incr server, cache_key, amount
    end
  rescue TypeError => err
    handle_error nil, err
  end

  ##
  # Add +key+ to the cache with value +value+ that expires in +expiry+
  # seconds.  If +raw+ is true, +value+ will not be Marshalled.
  #
  # Warning: Readers should not call this method in the event of a cache miss;
  # see MemCacheDb#add.

  ONE_MB = 1024 * 1024

  def set(key, value, expiry = 0, raw = false)
    raise MemCacheDbError, "Update of readonly cache" if @readonly

    value = Marshal.dump value unless raw
    with_server(key) do |server, cache_key|
      logger.debug { "set #{key} to #{server.inspect}: #{value.to_s.size}" } if logger

      if @check_size && value.to_s.size > ONE_MB
        raise MemCacheDbError, "Value too large, MemCacheDbd can only store 1MB of data per key"
      end

      command = "set #{cache_key} 0 #{expiry} #{value.to_s.size}#{noreply}\r\n#{value}\r\n"

      with_socket_management(server) do |socket|
        socket.write command
        break nil if @no_reply
        result = socket.gets
        raise_on_error_response! result

        if result.nil?
          server.close
          raise MemCacheDbError, "lost connection to #{server.host}:#{server.port}"
        end

        result
      end
    end
  end

  ##
  # "cas" is a check and set operation which means "store this data but
  # only if no one else has updated since I last fetched it."  This can
  # be used as a form of optimistic locking.
  #
  # Works in block form like so:
  #   cache.cas('some-key') do |value|
  #     value + 1
  #   end
  #
  # Returns:
  # +nil+ if the value was not found on the MemCacheDbd server.
  # +STORED+ if the value was updated successfully
  # +EXISTS+ if the value was updated by someone else since last fetch

  def cas(key, expiry=0, raw=false)
    raise MemCacheDbError, "Update of readonly cache" if @readonly
    raise MemCacheDbError, "A block is required" unless block_given?

    (value, token) = gets(key, raw)
    return nil unless value
    updated = yield value
    value = raw ? updated : Marshal.dump(updated)

    with_server(key) do |server, cache_key|
      logger.debug { "cas #{key} to #{server.inspect}: #{value.to_s.size}" } if logger
      command = "cas #{cache_key} 0 #{expiry} #{value.to_s.size} #{token}#{noreply}\r\n#{value}\r\n"

      with_socket_management(server) do |socket|
        socket.write command
        break nil if @no_reply
        result = socket.gets
        raise_on_error_response! result

        if result.nil?
          server.close
          raise MemCacheDbError, "lost connection to #{server.host}:#{server.port}"
        end

        result
      end
    end
  end

  ##
  # Add +key+ to the cache with value +value+ that expires in +expiry+
  # seconds, but only if +key+ does not already exist in the cache.
  # If +raw+ is true, +value+ will not be Marshalled.
  #
  # Readers should call this method in the event of a cache miss, not
  # MemCacheDb#set.

  def add(key, value, expiry = 0, raw = false)
    raise MemCacheDbError, "Update of readonly cache" if @readonly
    value = Marshal.dump value unless raw
    with_server(key) do |server, cache_key|
      logger.debug { "add #{key} to #{server}: #{value ? value.to_s.size : 'nil'}" } if logger
      command = "add #{cache_key} 0 #{expiry} #{value.to_s.size}#{noreply}\r\n#{value}\r\n"

      with_socket_management(server) do |socket|
        socket.write command
        break nil if @no_reply
        result = socket.gets
        raise_on_error_response! result
        result
      end
    end
  end

  ##
  # Add +key+ to the cache with value +value+ that expires in +expiry+
  # seconds, but only if +key+ already exists in the cache.
  # If +raw+ is true, +value+ will not be Marshalled.
  def replace(key, value, expiry = 0, raw = false)
    raise MemCacheDbError, "Update of readonly cache" if @readonly
    value = Marshal.dump value unless raw
    with_server(key) do |server, cache_key|
      logger.debug { "replace #{key} to #{server}: #{value ? value.to_s.size : 'nil'}" } if logger
      command = "replace #{cache_key} 0 #{expiry} #{value.to_s.size}#{noreply}\r\n#{value}\r\n"

      with_socket_management(server) do |socket|
        socket.write command
        break nil if @no_reply
        result = socket.gets
        raise_on_error_response! result
        result
      end
    end
  end

  ##
  # Append - 'add this data to an existing key after existing data'
  # Please note the value is always passed to MemCacheDbd as raw since it
  # doesn't make a lot of sense to concatenate marshalled data together.
  def append(key, value)
    raise MemCacheDbError, "Update of readonly cache" if @readonly
    with_server(key) do |server, cache_key|
      logger.debug { "append #{key} to #{server}: #{value ? value.to_s.size : 'nil'}" } if logger
      command = "append #{cache_key} 0 0 #{value.to_s.size}#{noreply}\r\n#{value}\r\n"

      with_socket_management(server) do |socket|
        socket.write command
        break nil if @no_reply
        result = socket.gets
        raise_on_error_response! result
        result
      end
    end
  end

  ##
  # Prepend - 'add this data to an existing key before existing data'
  # Please note the value is always passed to MemCacheDbd as raw since it
  # doesn't make a lot of sense to concatenate marshalled data together.
  def prepend(key, value)
    raise MemCacheDbError, "Update of readonly cache" if @readonly
    with_server(key) do |server, cache_key|
      logger.debug { "prepend #{key} to #{server}: #{value ? value.to_s.size : 'nil'}" } if logger
      command = "prepend #{cache_key} 0 0 #{value.to_s.size}#{noreply}\r\n#{value}\r\n"

      with_socket_management(server) do |socket|
        socket.write command
        break nil if @no_reply
        result = socket.gets
        raise_on_error_response! result
        result
      end
    end
  end

  ##
  # Removes +key+ from the cache.
  # +expiry+ is ignored as it has been removed from the latest MemCacheDbd version.

  def delete(key, expiry = 0)
    raise MemCacheDbError, "Update of readonly cache" if @readonly
    with_server(key) do |server, cache_key|
      with_socket_management(server) do |socket|
        logger.debug { "delete #{cache_key} on #{server}" } if logger
        socket.write "delete #{cache_key}#{noreply}\r\n"
        break nil if @no_reply
        result = socket.gets
        raise_on_error_response! result
        result
      end
    end
  end



  ##
  # Returns statistics for each MemCacheDbd server.  An explanation of the
  # statistics can be found in the MemCacheDbd docs:
  #
  # http://code.sixapart.com/svn/MemCacheDbd/trunk/server/doc/protocol.txt
  #
  # Example:
  #
  #   >> pp CACHE.stats
  #   {"localhost:11211"=>
  #     {"bytes"=>4718,
  #      "pid"=>20188,
  #      "connection_structures"=>4,
  #      "time"=>1162278121,
  #      "pointer_size"=>32,
  #      "limit_maxbytes"=>67108864,
  #      "cmd_get"=>14532,
  #      "version"=>"1.2.0",
  #      "bytes_written"=>432583,
  #      "cmd_set"=>32,
  #      "get_misses"=>0,
  #      "total_connections"=>19,
  #      "curr_connections"=>3,
  #      "curr_items"=>4,
  #      "uptime"=>1557,
  #      "get_hits"=>14532,
  #      "total_items"=>32,
  #      "rusage_system"=>0.313952,
  #      "rusage_user"=>0.119981,
  #      "bytes_read"=>190619}}
  #   => nil

  def stats
    raise MemCacheDbError, "No active servers" unless active?
    server_stats = {}

    @groups.each do |group|
      group.servers.each do |server|
        next unless server.alive?

        with_socket_management(server) do |socket|
          value = nil
          socket.write "stats\r\n"
          stats = {}
          while line = socket.gets do
            raise_on_error_response! line
            break if line == "END\r\n"
            if line =~ /\ASTAT ([\S]+) ([\w\.\:]+)/ then
              name, value = $1, $2
              stats[name] = case name
                            when 'version'
                              value
                            when 'rusage_user', 'rusage_system' then
                              seconds, microseconds = value.split(/:/, 2)
                              microseconds ||= 0
                              Float(seconds) + (Float(microseconds) / 1_000_000)
                            else
                              if value =~ /\A\d+\Z/ then
                                value.to_i
                              else
                                value
                              end
                            end
            end
          end
          server_stats["#{server.host}:#{server.port}"] = stats
        end
      end
    end

    raise MemCacheDbError, "No active servers" if server_stats.empty?
    server_stats
  end

  ##
  # Shortcut to get a value from the cache.

  alias [] get

  ##
  # Shortcut to save a value in the cache.  This method does not set an
  # expiration on the entry.  Use set to specify an explicit expiry.

  def []=(key, value)
    set key, value
  end
  
  
  ##
  # Gets or creates a socket connected to the given server, and yields it
  # to the block, wrapped in a mutex synchronization if @multithread is true.
  #
  # If a socket error (SocketError, SystemCallError, IOError) or protocol error
  # (MemCacheDbError) is raised by the block, closes the socket, attempts to
  # connect again, and retries the block (once).  If an error is again raised,
  # reraises it as MemCacheDbError.
  #
  # If unable to connect to the server (or if in the reconnect wait period),
  # raises MemCacheDbError.  Note that the socket connect code marks a server
  # dead for a timeout period, so retrying does not apply to connection attempt
  # failures (but does still apply to unexpectedly lost connections etc.).

  def with_socket_management(server, &block)
    check_multithread_status!
    @mutex.lock if @multithread
    retried = false

    begin
      socket = server.socket
      # Raise an IndexError to show this server is out of whack. If were inside
      # a with_server block, we'll catch it and attempt to restart the operation.

      raise IndexError, "No connection to server (#{server.status})" if socket.nil?

      block.call(socket)

    rescue SocketError, Errno::EAGAIN, Timeout::Error => err
      
      logger.warn { "Socket failure: #{err.message}" } if logger
      server.mark_dead(err)
      handle_error(server, err)

    rescue MemCacheDbError, SystemCallError, IOError => err
      logger.warn { "Generic failure: #{err.class.name}: #{err.message}" } if logger
      handle_error(server, err) if retried || socket.nil?
      retried = true
      retry
    end
  ensure
    @mutex.unlock if @multithread
  end

  protected unless $TESTING

  ##
  # Create a key for the cache, incorporating the namespace qualifier if
  # requested.

  def make_cache_key(key)
    if @autofix_keys && (key =~ /\s/ || key_length(key) > 250)
      key = "#{Digest::SHA1.hexdigest(key)}-autofixed"
    end

    if namespace.nil?
      key
    else
      "#{@namespace}#{@namespace_separator}#{key}"
    end
  end

  ##
  # Calculate length of the key, including the namespace and namespace-separator.

  def key_length(key)
    key.length + (namespace.nil? ? 0 : ( namespace.length + (@namespace_separator.nil? ? 0 : @namespace_separator.length) ) )
  end

  ##
  # Returns an interoperable hash value for +key+.  (I think, docs are
  # sketchy for down servers).

  def hash_for(key)
    Zlib.crc32(key)
  end

  ##
  # Pick a group to handle the request based on a hash of the key.

  def get_group_for_key(key, options = {})
    raise ArgumentError, "illegal character in key #{key.inspect}" if
      key =~ /\s/
    raise ArgumentError, "key too long #{key.inspect}" if key.length > 250
    raise MemCacheDbError, "No servers available" if @groups.empty?
    return @groups.first if @groups.length == 1

    hkey = hash_for(key)

    20.times do |try|
      entryidx = Continuum.binary_search(@continuum, hkey)
      server = @continuum[entryidx].server
      return server if server.alive?
      break unless failover
      hkey = hash_for "#{try}#{key}"
    end

    raise MemCacheDbError, "No servers available"
  end

  ##
  # Performs a raw decr for +cache_key+ from +server+.  Returns nil if not
  # found.

  def cache_decr(server, cache_key, amount)
    with_socket_management(server) do |socket|
      socket.write "decr #{cache_key} #{amount}#{noreply}\r\n"
      break nil if @no_reply
      text = socket.gets
      raise_on_error_response! text
      return nil if text == "NOT_FOUND\r\n"
      return text.to_i
    end
  end

  ##
  # Fetches the raw data for +cache_key+ from +server+.  Returns nil on cache
  # miss.

  def cache_get(server, cache_key)
    with_socket_management(server) do |socket|
      socket.write "get #{cache_key}\r\n"
      keyline = socket.gets # "VALUE <key> <flags> <bytes>\r\n"

      if keyline.nil? then
        server.close
        raise MemCacheDbError, "lost connection to #{server.host}:#{server.port}"
      end

      raise_on_error_response! keyline
      return nil if keyline == "END\r\n"

      unless keyline =~ /(\d+)\r/ then
        server.close
        raise MemCacheDbError, "unexpected response #{keyline.inspect}"
      end
      value = socket.read $1.to_i
      socket.read 2 # "\r\n"
      socket.gets   # "END\r\n"
      return value
    end
  end

  def gets(key, raw = false)
    with_server(key, true) do |server, cache_key|
      logger.debug { "gets #{key} from #{server.inspect}" } if logger
      result = with_socket_management(server) do |socket|
        socket.write "gets #{cache_key}\r\n"
        keyline = socket.gets # "VALUE <key> <flags> <bytes> <cas token>\r\n"
        
        if keyline.nil? then
          server.close
          raise MemCacheDbError, "lost connection to #{server.host}:#{server.port}"
        end

        raise_on_error_response! keyline
        return nil if keyline == "END\r\n"

        unless keyline =~ /(\d+) (\w+)\r/ then
          server.close
          raise MemCacheDbError, "unexpected response #{keyline.inspect}"
        end
        value = socket.read $1.to_i
        socket.read 2 # "\r\n"
        socket.gets   # "END\r\n"
        [value, $2]
      end
      result[0] = Marshal.load result[0] unless raw
      result
    end
  rescue TypeError => err
    handle_error nil, err
  end


  ##
  # Fetches +cache_keys+ from +server+ using a multi-get.

  def cache_get_multi(server, cache_keys)
    with_socket_management(server) do |socket|
      values = {}
      socket.write "get #{cache_keys}\r\n"
      
      while keyline = socket.gets do
        return values if keyline == "END\r\n"
        raise_on_error_response! keyline

        unless keyline =~ /\AVALUE (.+) (.+) (.+)/ then
          server.close
          raise MemCacheDbError, "unexpected response #{keyline.inspect}"
        end

        key, data_length = $1, $3
        values[$1] = socket.read data_length.to_i
        socket.read(2) # "\r\n"
      end

      server.close
      raise MemCacheDbError, "lost connection to #{server.host}:#{server.port}" # TODO: retry here too
    end
  end

  ##
  # Performs a raw incr for +cache_key+ from +server+.  Returns nil if not
  # found.

  def cache_incr(server, cache_key, amount)
    with_socket_management(server) do |socket|
      socket.write "incr #{cache_key} #{amount}#{noreply}\r\n"
      break nil if @no_reply
      text = socket.gets
      raise_on_error_response! text
      return nil if text == "NOT_FOUND\r\n"
      return text.to_i
    end
  end

  def with_server(key, read = false)
    retried = false
    begin
      server, cache_key = request_setup(key, read)
      yield server, cache_key
    rescue IndexError => e
      logger.warn { "Server failed: #{e.class.name}: #{e.message}" } if logger
      if !retried && @groups.size > 1
        logger.info { "Connection to server #{server.inspect} DIED! Retrying operation..." } if logger
        retried = true
        retry
      end
      handle_error(nil, e)
    end
  end

  ##
  # Handles +error+ from +server+.

  def handle_error(server, error)
    raise error if error.is_a?(MemCacheDbError)
    server.close if server && server.status == "CONNECTED"
    new_error = MemCacheDbError.new error.message
    new_error.set_backtrace error.backtrace
    raise new_error
  end

  def noreply
    @no_reply ? ' noreply' : ''
  end

  ##
  # Performs setup for making a request with +key+ from MemCacheDbd.  Returns
  # the server to fetch the key from and the complete key to use.

  def request_setup(key, read = false)
    raise MemCacheDbError, 'No active servers' unless active?
    cache_key = make_cache_key key
    group = get_group_for_key cache_key
    server = read ? group.next_slave : group.master
    return server, cache_key
  end

  def raise_on_error_response!(response)
    if response =~ /\A(?:CLIENT_|SERVER_)?ERROR(.*)/
      raise MemCacheDbError, $1.strip
    end
  end

  def create_continuum_for(groups)
    total_weight = groups.inject(0) { |memo, gr| memo + gr.weight }
    continuum = []

    groups.each do |group|
      entry_count_for(group, groups.size, total_weight).times do |idx|
        hash = Digest::SHA1.hexdigest("#{group.name}:#{idx}")
        value = Integer("0x#{hash[0..7]}")
        continuum << Continuum::Entry.new(value, group)
      end
    end

    continuum.sort { |a, b| a.value <=> b.value }
  end

  def entry_count_for(server, total_servers, total_weight)
    ((total_servers * Continuum::POINTS_PER_SERVER * server.weight) / Float(total_weight)).floor
  end

  def check_multithread_status!
    return if @multithread

    if Thread.current[:memcachedb_client] != self.object_id
      raise MemCacheDbError, <<-EOM
        You are accessing this MemCacheDb-client instance from multiple threads but have not enabled multithread support.
        Normally:  MemCacheDb.new(['localhost:11211'], :multithread => true)
        In Rails:  config.cache_store = [:mem_cache_store, 'localhost:11211', { :multithread => true }]
      EOM
    end
  end


  class Group
      attr_reader :weight
      attr_reader :servers
      attr_reader :name
      
      def initialize(memcache, servers, name, weight)
        @memcache = memcache
        @logger = memcache.logger
        @servers = servers
        @slaves = []
        @weight = weight || DEFAULT_WEIGHT
        @roundrobin = 0
        @name = name || 'default'
        determine_master
      end
      
      def master
        determine_master unless @master.alive?
        @master
      end
      
      def next_slave
        @roundrobin = ((@roundrobin + 1) >= @slaves.size ? 0 : @roundrobin + 1)
        server = @slaves[@roundrobin]
        server = next_slave unless server.alive?
        server
      end
      
      
      def alive?
        master.alive?
      end
      
     protected 
      def determine_master
        @slaves = []
        @servers.each do |s|
          if s.alive?
            #check if able to write
            command = "set CLIENT_TEST_MASTER 0 0 1\r\n0\r\n"

            @memcache.with_socket_management(s) do |socket|
              socket.write command
              result = socket.gets
              if result == "STORED\r\n"
                #this is the master
                @master = s
                break
              end
            end
          end
        end
        #masters can also be used to read
        @slaves = @servers
        raise MemCacheDbError.new 'No Master Server found' if @master.nil?
        p "Using master #{@master.host}:#{@master.port}"
        @logger.info "Using master #{@master}" if @logger
        @logger.info "Using slaves #{@slaves}" if @logger
      end
  end

  ##
  # This class represents a memcached server instance.

  class Server

    ##
    # The amount of time to wait before attempting to re-establish a
    # connection with a server that is marked dead.

    RETRY_DELAY = 30.0

    ##
    # The host the memcached server is running on.

    attr_reader :host

    ##
    # The port the memcached server is listening on.

    attr_reader :port

    ##
    # The weight given to the server.

    attr_reader :weight

    ##
    # The time of next retry if the connection is dead.

    attr_reader :retry

    ##
    # A text status string describing the state of the server.

    attr_reader :status

    attr_reader :logger

    ##
    # Create a new MemCacheDb::Server object for the memcached instance
    # listening on the given host and port, weighted by the given weight.

    def initialize(memcache, host, port = DEFAULT_PORT, weight = DEFAULT_WEIGHT)
      raise ArgumentError, "No host specified" if host.nil? or host.empty?
      raise ArgumentError, "No port specified" if port.nil? or port.to_i.zero?

      @host   = host
      @port   = port.to_i
      @weight = weight.to_i

      @sock   = nil
      @retry  = nil
      @status = 'NOT CONNECTED'
      @timeout = memcache.timeout
      @logger = memcache.logger
    end

    ##
    # Return a string representation of the server object.

    def inspect
      "<MemCacheDb::Server: %s:%d [%d] (%s)>" % [@host, @port, @weight, @status]
    end

    ##
    # Check whether the server connection is alive.  This will cause the
    # socket to attempt to connect if it isn't already connected and or if
    # the server was previously marked as down and the retry time has
    # been exceeded.

    def alive?
      !!socket
    end

    ##
    # Try to connect to the memcached server targeted by this object.
    # Returns the connected socket object on success or nil on failure.

    def socket
      return @sock if @sock and not @sock.closed?

      @sock = nil

      # If the host was dead, don't retry for a while.
      return if @retry and @retry > Time.now

      # Attempt to connect if not already connected.
      begin
        @sock = connect_to(@host, @port, @timeout)
        @sock.setsockopt Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1
        @retry  = nil
        @status = 'CONNECTED'
      rescue SocketError, SystemCallError, IOError, Timeout::Error => err
        logger.warn { "Unable to open socket: #{err.class.name}, #{err.message}" } if logger
        mark_dead err
      end

      return @sock
    end

    def connect_to(host, port, timeout=nil)
      sock = nil
      if timeout
        MemCacheDbTimer.timeout(timeout) do
          sock = TCPSocket.new(host, port)
        end
      else
        sock = TCPSocket.new(host, port)
      end

      io = MemCacheDb::BufferedIO.new(sock)
      io.read_timeout = timeout
      # Getting reports from several customers, including 37signals,
      # that the non-blocking timeouts in 1.7.5 don't seem to be reliable.
      # It can't hurt to set the underlying socket timeout also, if possible.
      if timeout
        secs = Integer(timeout)
        usecs = Integer((timeout - secs) * 1_000_000)
        optval = [secs, usecs].pack("l_2")
        begin
          io.setsockopt Socket::SOL_SOCKET, Socket::SO_RCVTIMEO, optval
          io.setsockopt Socket::SOL_SOCKET, Socket::SO_SNDTIMEO, optval
        rescue Exception => ex
          # Solaris, for one, does not like/support socket timeouts.
          @logger.info "[memcachedb-client] Unable to use raw socket timeouts: #{ex.class.name}: #{ex.message}" if @logger
        end
      end
      io
    end

    ##
    # Close the connection to the memcached server targeted by this
    # object.  The server is not considered dead.

    def close
      @sock.close if @sock && !@sock.closed?
      @sock   = nil
      @retry  = nil
      @status = "NOT CONNECTED"
    end

    ##
    # Mark the server as dead and close its socket.

    def mark_dead(error)
      @sock.close if @sock && !@sock.closed?
      @sock   = nil
      @retry  = Time.now + RETRY_DELAY

      reason = "#{error.class.name}: #{error.message}"
      @status = sprintf "%s:%s DEAD (%s), will retry at %s", @host, @port, reason, @retry
      @logger.info { @status } if @logger
    end

  end

  ##
  # Base MemCacheDb exception class.

  class MemCacheDbError < RuntimeError; end

  class BufferedIO < Net::BufferedIO # :nodoc:
    BUFSIZE = 1024 * 16

    if RUBY_VERSION < '1.9.1'
      def rbuf_fill
        begin
          @rbuf << @io.read_nonblock(BUFSIZE)
        rescue Errno::EWOULDBLOCK
          retry unless @read_timeout
          if IO.select([@io], nil, nil, @read_timeout)
            retry
          else
            raise Timeout::Error, 'IO timeout'
          end
        end
      end
    end

    def setsockopt(*args)
      @io.setsockopt(*args)
    end

    def gets
      readuntil("\n")
    end
  end

end

module Continuum
  POINTS_PER_SERVER = 160 # this is the default in libmemcached

  # Find the closest index in Continuum with value <= the given value
  def self.binary_search(ary, value, &block)
    upper = ary.size - 1
    lower = 0
    idx = 0

    while(lower <= upper) do
      idx = (lower + upper) / 2
      comp = ary[idx].value <=> value

      if comp == 0
        return idx
      elsif comp > 0
        upper = idx - 1
      else
        lower = idx + 1
      end
    end
    return upper
  end

  class Entry
    attr_reader :value
    attr_reader :server

    def initialize(val, srv)
      @value = val
      @server = srv
    end

    def inspect
      "<#{value}, #{server.host}:#{server.port}>"
    end
  end

end
require 'continuum_native'

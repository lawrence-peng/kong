local spec_helper = require "spec.spec_helpers"
local constants = require "kong.constants"
local stringy = require "stringy"
local IO = require "kong.tools.io"
local fs = require "luarocks.fs"

describe("Static files", function()

  describe("Constants", function()

    it("version set in constants should match the one in the rockspec", function()
      local rockspec_path
      for _, filename in ipairs(fs.list_dir(".")) do
        if stringy.endswith(filename, "rockspec") then
          rockspec_path = filename
          break
        end
      end

      if not rockspec_path then
        error("Can't find the rockspec file")
      end

      local file_content = IO.read_file(rockspec_path)
      local res = file_content:match("\"+[0-9.-]+[a-z]*[0-9-]*\"+")
      local extracted_version = res:sub(2, res:len() - 1)
      assert.are.same(constants.VERSION, extracted_version)
    end)

  end)

  describe("Configuration", function()

    it("should parse a correct configuration", function()
      local configuration = IO.read_file(spec_helper.DEFAULT_CONF_FILE)

      assert.are.same([[
# Available plugins on this server
plugins_available:
  - keyauth
  - basicauth
  - ratelimiting
  - tcplog
  - udplog
  - filelog
  - cors
  - request_transformer

nginx_working_dir: /usr/local/kong/

proxy_port: 8000
admin_api_port: 8001

# Specify the DAO to use
database: cassandra

# Databases configuration
databases_available:
  cassandra:
    properties:
      hosts: "localhost"
      port: 9042
      timeout: 1000
      keyspace: kong
      keepalive: 60000

# Cassandra cache configuration
database_cache_expiration: 5 # in seconds

# Sends anonymous error reports
send_anonymous_reports: true

# Nginx configuration
nginx: |
  worker_processes auto;
  error_log logs/error.log info;
  daemon on;

  worker_rlimit_nofile {{auto_worker_rlimit_nofile}};

  env KONG_CONF;

  events {
    worker_connections {{auto_worker_connections}};
    multi_accept on;
  }

  http {
    resolver 8.8.8.8;
    charset UTF-8;

    access_log logs/access.log;
    access_log on;

    # Timeouts
    keepalive_timeout 60s;
    client_header_timeout 60s;
    client_body_timeout 60s;
    send_timeout 60s;

    # Proxy Settings
    proxy_buffer_size 128k;
    proxy_buffers 4 256k;
    proxy_busy_buffers_size 256k;
    proxy_ssl_server_name on;

    # IP Address
    real_ip_header X-Forwarded-For;
    set_real_ip_from 0.0.0.0/0;
    real_ip_recursive on;

    # Other Settings
    client_max_body_size 128m;
    underscores_in_headers on;
    reset_timedout_connection on;
    tcp_nopush on;

    ################################################
    #  The following code is required to run Kong  #
    # Please be careful if you'd like to change it #
    ################################################

    # Lua Settings
    lua_package_path ';;';
    lua_code_cache on;
    lua_max_running_timers 4096;
    lua_max_pending_timers 16384;
    lua_shared_dict cache 512m;
    lua_socket_log_errors off;

    init_by_lua '
      kong = require "kong"
      local status, err = pcall(kong.init)
      if not status then
        ngx.log(ngx.ERR, "Startup error: "..err)
        os.exit(1)
      end
    ';

    server {
      listen {{proxy_port}};

      location / {
        default_type 'text/plain';

        # This property will be used later by proxy_pass
        set $backend_url nil;

        # Authenticate the user and load the API info
        access_by_lua 'kong.exec_plugins_access()';

        # Proxy the request
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_pass $backend_url;
        proxy_pass_header Server;

        # Add additional response headers
        header_filter_by_lua 'kong.exec_plugins_header_filter()';

        # Change the response body
        body_filter_by_lua 'kong.exec_plugins_body_filter()';

        # Log the request
        log_by_lua 'kong.exec_plugins_log()';
      }

      location /robots.txt {
        return 200 'User-agent: *\nDisallow: /';
      }

      error_page 500 /500.html;
      location = /500.html {
        internal;
        content_by_lua '
          local utils = require "kong.tools.utils"
          utils.show_error(ngx.status, "Oops, an unexpected error occurred!")
        ';
      }
    }

    server {
      listen {{admin_api_port}};

      location / {
        default_type application/json;
        content_by_lua 'require("lapis").serve("kong.api.app")';
      }

      location /robots.txt {
        return 200 'User-agent: *\nDisallow: /';
      }

      # Do not remove, additional configuration placeholder for some plugins
      # {{additional_configuration}}
    }
  }
]], configuration)
    end)

  end)
end)
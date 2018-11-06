local _M = require('apicast.policy').new('Load Configuration')
local ssl = require('ngx.ssl')

local configuration_loader = require('apicast.configuration_loader').new()
local configuration_store = require('apicast.configuration_store')

local new = _M.new

_M.configuration = configuration_store.new()

function _M.new(...)
    local policy = new(...)
    policy.configuration = _M.configuration
    return policy
end

function _M:export()
    return {
        configuration = self.configuration
    }
end

local once = function(fun)
    local executed = false
    return function(...)
        if not executed then
            executed = true
            return fun(...)
        end
    end
end

local function init()
    configuration_loader.init(_M.configuration)
end
_M.init = once(init)

local function init_worker()
    configuration_loader.init_worker(_M.configuration)
end
_M.init_worker = once(init_worker)

function _M:rewrite(context)
    context.host = context.host or ngx.var.host
    context.configuration = configuration_loader.rewrite(self.configuration, context.host)
end

function _M.ssl_certificate(_, context)
    if not context.host then
        local server_name, err = ssl.server_name()

        if server_name then
            context.host = server_name
        elseif err then
            ngx.log(ngx.DEBUG, 'could not get TLS SNI server name: ', err)
        end
    end
end

return _M

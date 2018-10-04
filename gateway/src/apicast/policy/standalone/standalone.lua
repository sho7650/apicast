-- This is a standalone description.

local Policy = require('apicast.policy')
local PolicyChain = require('apicast.policy_chain')
local Upstream = require('apicast.upstream')
local Configuration = require('apicast.policy.standalone.configuration')
local resty_env = require('resty.env')
local _M = Policy.new('standalone')
local tab_new = require('resty.core.base').new_tab
local insert = table.insert
local pairs = pairs

local setmetatable = setmetatable

local function load_configuration(url)
  local configuration, err = Configuration.new(url)

  if configuration then
    configuration, err = configuration:load()
  end

  return configuration, err
end

local new = _M.new
--- Initialize the Standalone APIcast policy
-- @tparam[opt] table config Policy configuration.
function _M.new(config)
  local self = new(config)

  self.url = (config and config.url) or resty_env.get('APICAST_CONFIGURATION')

  return self
end

-- forward all policy request methods to the policy chain
for _,phase in Policy.request_phases() do
  _M[phase] = function(self, context, ...)
    return context[self][phase](context[self], context, ...)
  end
end

local function build_objects(constructor, list)
  if not list then return nil end

  local objects = tab_new(#list, 0)

  for i=1, #list do
    local object = constructor(list[i])

    if object.name then
      objects[object.name] = object
    else
      objects[i] = object
    end
  end

  return objects
end

local Route = { }

local function build_routes(configuration)
  return build_objects(Route.new, configuration.routes)
end

local Destination = { }
do
  local Destination_mt = { __index = Destination }

  function Destination.new(config)
    if not config then return nil end

    return setmetatable({
      service = config.service,
      http_response = config.http_response,
    }, Destination_mt)
  end
end

local Condition = { }
do

  local Condition_mt = { __index = Condition }

  local operations = {
    server_port = function(self) return ngx.var.server_port == self.value end,
    always = function(self) return self.value end,
    unknown = function(self) ngx.log(ngx.ERR, 'unknown condition ', self.name); return end
  }

  function Condition.new(name, value)
    return setmetatable({
        fun = operations[name] or operations.unknown,
        value = value,
        name = name,
    }, Condition_mt)
  end

  function Condition:match(context)
    return self.fun(self)
  end
end

local Match = { }
do
  local Match_mt = { __index = Match }

  function Match.new(config)
    local matchers = { }

    for name, value in pairs(config) do
      insert(matchers, Condition.new(name, value))
    end

    return setmetatable(matchers, Match_mt)
  end

  function Match:any(context)
    for i=1, #self do
      if self[i]:match(context) then
        return self[i]
      end
    end
  end
end

do
  local Route_mt = { __index = Route }

  function Route.new(config)
    return setmetatable({
      conditions = Match.new(config.match),
      destination = Destination.new(config.destination),
      routes = build_routes(config),
    }, Route_mt)
  end

  function Route:match(context)
    return self.conditions:any(context)
  end
end

local Service = { }

local function build_services(configuration)
  return build_objects(Service.new, configuration.internal)
end

do
  local Service_mt = { __index = Service }

  local function build_policy_chain(policies)
    local chain = tab_new(#policies, 0)

    for i=1, #policies do
      local policy, err = PolicyChain.load_policy(policies[i].policy, policies[i].version, policies[i].configuration)

      if policy then
        insert(chain, policy)
      elseif err then
        ngx.log(ngx.WARN, 'failed to load policy: ', policies[i].policy, ' version: ', policies[i].version, ' err: ', err)
      end
    end

    return PolicyChain.new(chain)
  end

  function Service.new(config)
    return setmetatable({
      name = config.name,
      upstream = Upstream.new(config.upstream),
      policy_chain = build_policy_chain(config.policy_chain),
    }, Service_mt)
  end
end

local External = { }

local function build_upstreams(configuration)
  return build_objects(External.new, configuration.external)
end

do
  local External_mt = { __index = External }

  function External.new(config)
    return setmetatable({
      name = config.name,
      server = Upstream.new(config.server),
      load_balancer = config.load_balancer,
      retries = config.retries,
    }, External_mt)
  end
end

local default = {
  services = build_objects(Service.new, {
    { name = 'not_found',
      policy_chain = {
        { policy = 'apicast.policy.echo', configuration = { status = ngx.HTTP_NOT_FOUND } },
      },
    },
  }),
}

local function init_configuration(self, context)
  local url = self.url

  if not url then
    return nil, 'not initialized'
  end

  local configuration, err = load_configuration(url)

  if configuration then
    self.routes = build_routes(configuration)
    self.services = setmetatable(build_services(configuration), { __index = default.services })
    self.upstreams = build_upstreams(configuration)
  else
    ngx.log(ngx.WARN, 'failed to load ', url, ' err: ', err)
    return nil, err
  end
end

function _M:init(context)
  if self then -- initializing policy instance
    return init_configuration(self)
  end
end

local function find_route(routes, context)
  for i=1, #routes do
    if routes[i]:match(context) then return routes[i] end
  end
end

local empty_chain = PolicyChain.new()

function _M:dispatch(route)
  local destination = route and route.destination
  local service = self.services[destination and destination.service]

  if service then
    return service.policy_chain or empty_chain
  else
    ngx.log(ngx.ERR, 'could not find the route destination')
  end
end

local rewrite = _M.rewrite

function _M:rewrite(context)
  local route = find_route(self.routes, context)

  context[self] = self:dispatch(route)

  return rewrite(self, context)
end

return _M

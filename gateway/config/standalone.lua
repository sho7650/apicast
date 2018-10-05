local PolicyChain = require('apicast.policy_chain')

local standalone = PolicyChain.load_policy(
        'apicast.policy.standalone',
        'builtin',
        { url = context.configuration })

if arg then -- running CLI to generate nginx config
    return {
        template = 'http.d/standalone.config.liquid',
        standalone = standalone:load_configuration(),
        configuration = standalone.url,
    }

else -- booting APIcast
    return {
        policy_chain = PolicyChain.new{
            standalone,
        },
        configuration = standalone.url,
    }
end

local PolicyChain = require('apicast.policy_chain')

if arg then -- running CLI to generate nginx config

else -- booting APIcast
    local policy_chain = PolicyChain.build{
        'apicast.policy.standalone',
    }
    return {
        policy_chain = policy_chain
    }
end

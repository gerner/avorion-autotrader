package.path = package.path .. ";data/scripts/lib/?.lua"

include("autotraderutility")

-- Don't remove or alter the following comment, it tells the game the namespace this script lives in. If you remove it, the script will break.
-- namespace AutoTrader 
AutoTrader = {}

local claimedRoutes = {}
-- list of claims:
--  entityIndex
--  goodName
--  buyIndex
--  amountToBuy
--  sellIndex
--  amountToSell

-- add route to the set of claimedRoutes
function AutoTrader.claimRoute(claimString)
    print("AutoTrader Coordination: claim route")

    local claim = RouteSerializer.deserializeClaim(claimString)
    printTable(claim)

    -- TODO: need any kind of claim timeout?
    claimedRoutes[claim.entityIndex] = claim
end

-- clear any claims by entity with entityIndex
function AutoTrader.clearClaims(entityIndex)
    print("AutoTrader Coordination: clear claim")
    claimedRoutes[Uuid(entityIndex)] = nil
end

-- send routes to entity with entityIndex in sector x, y
function AutoTrader.requestClaims(x, y, entityIndex)
    print("AutoTrader Coordination: routes request %1%:%2% %3%", x, y, entityIndex)

    invokeRemoteEntityFunction(x, y, nil, Uuid(entityIndex), "autotrader.lua", "receiveClaims", RouteSerializer.serializeClaims(claimedRoutes))
end

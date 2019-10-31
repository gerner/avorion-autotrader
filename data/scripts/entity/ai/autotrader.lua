package.path = package.path .. ";data/scripts/lib/?.lua"

include("utility")
include("autotraderutility")

DockAI = include("entity/ai/dock")
JumpAI = include("entity/ai/jump")

-- Don't remove or alter the following comment, it tells the game the namespace this script lives in. If you remove it, the script will break.
-- namespace AutoTrader 
AutoTrader = {}

States = {
    Stuck = -1,
    Search = 0,
    TravelToBuy = 1,
    Buy = 2,
    TravelToSell = 3,
    Sell = 4,
    Done = 5

}

local wasInited = false
local state = States.Search
local route = nil
local searchInterval = 1
local noRouteNotificationTimer = 0
local noRouteNotificationPeriod = 60

--optional filters on buying and selling
-- {
--     coords = nil, -- coordinates where to make the buy or sell
--     distance = nil, -- max distance from coords if not nil or max distance to travel for buy or sell
--     script = nil, -- only buy/sell from this script
--     station = nil, -- only buy/sell from stations whose title matches this
--     goodName = nil -- only trade goods with this name
-- }
local filterBuy = nil
local filterSell = nil

-- rough time to travel to a station, dock, do transaction, undock
-- in terms of jump cooldown
-- this is just an estimate to compare routes in terms of profit/time
local dockingOverheadTime = 3

local claimedRoutes = {}
-- list of claims:
--  goodName
--  buyIndex
--  amountToBuy
--  sellIndex
--  amountToSell

function AutoTrader.initialize()
    print("AutoTrader: initializing")
    -- make sure our parent faction has the coordination script
    -- TODO: will this work from our current context? shouldn't this happen in some init script somewhere?
    local parent = getParentFaction()
    if parent.isPlayer then
        parent = Player(parent.index)
    elseif parent.isAlliance then
        parent = Alliance(parent.index)
    end --else it's an AIFaction?

    parent:addScriptOnce("data/scripts/player/autotrader.lua")
    print("added script to parent faction")

    local x, y = Sector():getCoordinates()
    invokeRemoteFactionFunction(getParentFaction().index, "autotrader.lua", "requestClaims", x, y, Entity().index)

    -- kick tradingoverview to get data ready for us
    Entity():invokeFunction("tradingoverview.lua", "getData")

    -- TODO: handle being restored from disk
    searchInterval = 1
    state = States.Search
    AutoTrader.clearOurClaims()

    -- TODO: callbacks for cargo changing to keep track of trades actually working
end

function AutoTrader.onDelete()
    AutoTrader.clearOurClaims()
end

-- TODO: secure and restore methods

function AutoTrader.canContinueAutoTrading()
    if not wasInited then return true end
    -- TODO: what's the stopping condition for auto trading?
    return true
end

function AutoTrader.getUpdateInterval()
    if not wasInited then
        return 1
    elseif state == States.Search then
        -- periodically search for an updated trade route
        return searchInterval
    elseif state == States.Stuck then
        return 120
    else
        -- frequently update because we're doing active stuff like docking
        return 5
    end
end

function AutoTrader.updateServer(timeStep)
    wasInited = true

    local entity = Entity()

    -- must have a trading system
    if not entity:hasScript("tradingoverview.lua") then
        Faction():sendChatMessage("", ChatMessageType.Error, "You have to install a Trading System in the ship for Auto Trader to work."%_T)
        ShipAI():setPassive()
        terminate()
        return
    end

    -- must not be a station
    if entity.isStation then
        Faction():sendChatMessage("", ChatMessageType.Error, "Stations can't auto trade."%_T)
        ShipAI():setPassive()
        terminate()
        return
    end

    -- must have a captain
    if entity.hasPilot or ((entity.playerOwned or entity.allianceOwned) and entity:getCrewMembers(CrewProfessionType.Captain) == 0) then
        ShipAI():setPassive()
        terminate()
        return
    end

    if state == States.Search then
        AutoTrader.StateSearch(timeStep, entity)
    elseif state == States.TravelToBuy then
        AutoTrader.StateTravelToBuy(timeStep, entity)
    elseif state == States.Buy then
        AutoTrader.StateBuy(timeStep, entity)
    elseif state == States.TravelToSell then
        AutoTrader.StateTravelToSell(timeStep, entity)
    elseif state == States.Sell then
        AutoTrader.StateSell(timeStep, entity)
    elseif state == States.Done then
        AutoTrader.StateDone(timeStep, entity)
    else
        -- Stuck or some other unknown state
        AutoTrader.clearOurClaims()
        ShipAI():setStatus("Error in AutoTrader"%_T, {})
    end
end

-- Lifecycle:
-- 1) search for a route (have good -> sell or buy -> sell)
-- 2) travel to buy location
-- 3) buy the good
-- 4) travel to sell location
-- 5) sell the good

function AutoTrader.StateSearch(timeStep, entity)
    ShipAI():setStatus("Searching for a trade route /* ship AI status*/"%_T, {})

    -- TODO: consider multiple routes across a sequence of systems

    local foundRoute = AutoTrader.findRoute(entity)
    if foundRoute then
        print("AutoTrader: found a route")
        printTable(foundRoute)

        AutoTrader.claimRoute(routeCandidate)
        route = foundRoute

        if route.amountToBuy > 0 then
            print("AutoTrader: want to buy %1% units of %2%, travel to buy", route.amountToBuy, route.buyable.good.name)
            JumpAI.reset()
            state = States.TravelToBuy
        else
            print("AutoTrader: already have %1% units of %2%, travel to sell", route.amountToSell, route.buyable.good.name)
            JumpAI.reset()
            state = States.TravelToSell
        end

    else
        print("AutoTrader: no trade route found, will continue to search")
        -- let's wait a while before we look again
        searchInterval = 30
        -- update our view of claimed routes
        local x, y = Sector():getCoordinates()
        invokeRemoteFactionFunction(getParentFaction().index, "autotrader.lua", "requestClaims", x, y, entity.index)

        -- periodically notify the player/faction
        if noRouteNotificationTimer <= 0 then
            noRouteNotificationTimer = noRouteNotificationPeriod

            local faction = Faction(entity.factionIndex)
            local x, y = Sector():getCoordinates()
            local coords = tostring(x) .. ":" .. tostring(y)
            local shipName = Entity().name or ""
            local errorMessage = "Your ship in sector %s can't find any trade routes."%_T
            local chatMessage = "Sir, we can't find any trade routes in \\s(%s)!"%_T
            faction:sendChatMessage(shipName, ChatMessageType.Error, errorMessage, coords)
            faction:sendChatMessage(shipName, ChatMessageType.Normal, chatMessage, coords)
        else
            noRouteNotificationTimer = noRouteNotificationTimer - timeStep
        end
    end
end

function AutoTrader.StateTravelToBuy(timeStep, entity)
    ShipAI():setStatus("Traveling to ${x},${y} to buy ${amountToBuy} units of ${good} from ${stationName}"%_T, {x = route.buyable.coords.x, y = route.buyable.coords.y, amountToBuy = route.amountToBuy, good = route.buyable.good.name, stationName = (route.buyable.station%_t % route.buyable.titleArgs)})
    JumpAI.updateJumpToSector(route.buyable.coords.x, route.buyable.coords.y, AutoTrader.finishedJump)
end

function AutoTrader.StateBuy(timeStep, entity)
    local station = Sector():getEntity(route.buyable.stationIndex)

    -- TODO: make sure the station still exists and we can do our transaction

    ShipAI():setStatus("Buying ${amountToBuy} units of ${good} from ${stationName} in ${x}:${y}"%_T, {amountToBuy = route.amountToBuy, good = route.buyable.good.name, stationName = (route.buyable.station%_t % route.buyable.titleArgs), x=route.buyable.coords.x, y=route.buyable.coords.y})

    AutoTrader.dockAndTrade(timeStep, entity, station)
end

function AutoTrader.StateTravelToSell(timeStep, entity)
    ShipAI():setStatus("Traveling to ${x},${y} to sell ${amountToSell} units of ${good} from ${stationName}"%_T, {x = route.sellable.coords.x, y = route.sellable.coords.y, amountToSell = route.amountToSell, good = route.sellable.good.name, stationName = (route.sellable.station%_t % route.sellable.titleArgs)})
    JumpAI.updateJumpToSector(route.sellable.coords.x, route.sellable.coords.y, AutoTrader.finishedJump)
end

function AutoTrader.StateSell(timeStep, entity)
    local station = Sector():getEntity(route.sellable.stationIndex)

    -- TODO: make sure the station still exists and we can do our transaction

    ShipAI():setStatus("Selling ${amountToSell} units of ${good} to ${stationName} in ${x}:${y}"%_T, {amountToSell = route.amountToSell, good = route.sellable.good.name, stationName = (route.sellable.station%_t % route.sellable.titleArgs), x=route.sellable.coords.x, y=route.sellable.coords.y})
    AutoTrader.dockAndTrade(timeStep, entity, station)
end

function AutoTrader.StateDone(timeStep, entity)
    -- kick tradingoverview to get data ready for us
    entity:invokeFunction("tradingoverview.lua", "getData")

    -- release our claim
    AutoTrader.clearOurClaims()

    -- update our view of claimed routes
    local x, y = Sector():getCoordinates()
    invokeRemoteFactionFunction(getParentFaction().index, "autotrader.lua", "requestClaims", x, y, entity.index)

    -- wait a bit for tradingoverview to catch up, then search
    searchInterval = 1
    state = States.Search
end

-- multiple traders coordination functions

function AutoTrader.receiveClaimedRoutes(claims)
    claimedRoutes = RouteSerializer.deserializeClaims(claims)
end
-- TODO: do we need to declare this callable?
-- callable(AutoTrader, "receiveClaimedRoutes")

function AutoTrader.conflictsWithClaims(entity, routeCandidate)
    -- we should not grab a route which can't be fulfilled if existing
    -- routes are fulfilled
    -- stuff to check for
    -- not enough stock for claims buys + our route
    -- not enough space for claim sells + our route
    -- TODO: not enough cash claim buys + our route (seems like an edge condition)

    -- TODO: what if one of the claims already made a purchase, so our view of stock has already taken that into account?
    local totalBuy = 0
    local totalSell = 0
    for entityIndex, claim in pairs(claimedRoutes) do

        -- only care about claims on the same good
        if claim.goodName ~= routeCandidate.buyable.good.name then
            goto continue
        end

        -- skip our own claims
        if entityIndex == entity.index then
            goto continue
        end

        -- check buy-side
        if routeCandidate.buyable.stationIndex == claim.buyIndex then
            totalBuy  = totalBuy + claim.amountToBuy
        end

        if routeCandidate.sellable.stationIndex == claim.sellIndex then
            totalSell = totalSell + claim.amountToSell
        end

        ::continue::
    end

    if routeCandidate.amountToBuy > 0 and routeCandidate.buyable.stock < totalBuy + routeCandidate.amountToBuy then
        return true
    end

    if routeCandidate.amountToSell > 0 and (routeCandidate.maxStock - routeCandidate.stock) < totalSell + routeCandidate.amountToSell < 0 then
        return true
    end

    return false
end

function AutoTrader.claimRoute(routeCandidate)
    -- add to a faction-wide list of claimed routes
    -- TBD: remove any claims from us just to clean up?
    --  other reasons claims could go stale?

    invokeRemoteFactionFunction(getParentFaction().index, "autotrader.lua", "claimRoute", Entity().index, RouteSerializer.serializeClaim(RouteSerializer.routeToClaim(routeCandidate)))
    return
end

function AutoTrader.clearOurClaims()
    -- remove claims from our Entity from a faction-wide list of claims

    invokeRemoteFactionFunction(getParentFaction().index, "autotrader.lua", "clearClaims", Entity().index)
    return
end

-- finding a route functions

function AutoTrader.loadFilters(entity)
    local buyCoords = entity:getValue("AutoTrader_filterBuy_coords")
    if buyCoords ~= nil then
        local x,y = string.match(buyCoords, "(-?[0-9]+):(-?[0-9]+)")
        if not x or not y then
            buyCoords = nil
        else
            buyCoords = vec2(tonumber(x), tonumber(y))
        end
    end
    filterBuy = {
        goodName = entity:getValue("AutoTrader_filterBuy_goodName"),
        coords = buyCoords,
        distance = entity:getValue("AutoTrader_filterBuy_distance"),
        script = entity:getValue("AutoTrader_filterBuy_script"),
        station = entity:getValue("AutoTrader_filterBuy_station")
    }
    if filterBuy.coords ~= nil and not filterBuy.distance then
        filterBuy.distance = 0
    end

    local sellCoords = entity:getValue("AutoTrader_filterSell_coords")
    if sellCoords ~= nil then
        local x,y = string.match(buyCoords, "(-?[0-9]+):(-?[0-9]+)")
        if not x or not y then
            sellCoords = nil
        else
            sellCoords = vec2(tonumber(x), tonumber(y))
        end
    end
    filterSell = {
        goodName = entity:getValue("AutoTrader_filterSell_goodName"),
        coords = sellCoords,
        distance = entity:getValue("AutoTrader_filterSell_distance"),
        script = entity:getValue("AutoTrader_filterSell_script"),
        station = entity:getValue("AutoTrader_filterSell_station")
    }
    if filterSell.coords ~= nil and not filterSell.distance then
        filterSell.distance = 0
    end
end

function AutoTrader.filterTrade(filter, trade, coords)
    -- no filter allows everything
    if filter == nil then
        return true
    end

    if filter.goodName ~= nil and not string.match(trade.good.name, filter.goodName) then
        return false
    end

    if filter.coords ~= nil and distance(trade.coords, filter.coords) > filter.distance then
        return false
    elseif filter.distance ~= nil and distance(trade.coords, coords) > filter.distance then
        return false

    end

    if filter.script ~= nil and not string.match(trade.script, filter.script) then
        return false
    end

    if filter.station ~= nil and not string.match(trade.station, filter.station) then
        return false
    end

    return true
end

function AutoTrader.findRoute(ship)
    local x, y = Sector():getCoordinates()
    local currentCoords = vec2(x, y)

    AutoTrader.loadFilters(ship)

    local ok, sellable, buyable, routes = ship:invokeFunction("tradingoverview.lua", "getData")
    if not ok then
        print("error communicating with trading overview")
        return nil
    end

    -- check if we have the cargo ourselves
    local cargoBay = CargoBay()
    local selfCargos = {}
    for good, amount in pairs(cargoBay:getCargos()) do
        selfCargos[good.name] = amount
    end
    local freeCargo = cargoBay.freeSpace
    local money = getParentFaction().money

    local amountToBuyAndSell = function(money, freeCargo, amountOnHand, route)
        amountOnHand = amountOnHand or 0
        -- want to have as much as possible to saturate the destination
        -- combination of self cargo stock plus amount we can buy
        -- use self cargo first
        -- limit by cargo capacity and current money
        local maxSellable = route.sellable.maxStock - route.sellable.stock

        local maxBuyable = route.buyable.stock
        maxBuyable = math.min(maxBuyable, freeCargo / route.buyable.good.size)
        maxBuyable = math.min(maxBuyable, money / route.buyable.price)

        local amountToSell = math.min(maxSellable, amountOnHand + maxBuyable)
        local amountToBuy = math.max(0, amountToSell - amountOnHand)

        return amountToBuy, amountToSell
    end

    -- we're going to mess with the routes, so let's make a copy
    routes = table.deepcopy(routes)

    -- add pseudo routes to sell goods already on hand
    for _, sellable in pairs(sellable) do
        if selfCargos[sellable.good.name] and selfCargos[sellable.good.name] > 0 then
            local buyable = {
                good = sellable.good,
                price = 9999999999,
                coords = vec2(x, y),
                stock = 0,
                script = "self",
                station = "self",
                stationIndex = "self"
            }
            table.insert(routes, {buyable = buyable, sellable = sellable})
        end
    end

    for _, routeCandidate in pairs(routes) do
        local toBuy, toSell = amountToBuyAndSell(money, freeCargo, selfCargos[routeCandidate.buyable.good.name], routeCandidate)
        routeCandidate.amountToBuy = toBuy
        routeCandidate.amountToSell = toSell

        -- profit is total sale minus cost to buy,
        -- accounting for goods already on hand
        routeCandidate.profit = toSell * routeCandidate.sellable.price - toBuy * routeCandidate.buyable.price

        -- compute the number of jumps we have to make to reach destinations
        if routeCandidate.amountToBuy > 0 then
            routeCandidate.buyDist = JumpAI.estimateRouteLength(Entity(), x, y, routeCandidate.buyable.coords.x, routeCandidate.buyable.coords.y)
        else
            routeCandidate.buyDist = 0
        end
        routeCandidate.sellDist = JumpAI.estimateRouteLength(Entity(), routeCandidate.buyable.coords.x, routeCandidate.buyable.coords.y, routeCandidate.sellable.coords.x, routeCandidate.sellable.coords.y)

        -- note we subtract 1 from the distances below because I assume the
        -- first jump doesn't have to pay any cooldown overhead
        if routeCandidate.amountToBuy > 0 then
            routeCandidate.routeTime = dockingOverheadTime + math.max(routeCandidate.buyDist - 1, 0)
        else
            routeCandidate.routeTime = 0
        end
        routeCandidate.routeTime = routeCandidate.routeTime + dockingOverheadTime + math.max(routeCandidate.sellDist - 1, 0)

        print("%1% profit %2% time %3% p/t %4%", routeCandidate.buyable.good.name, routeCandidate.profit, routeCandidate.routeTime, routeCandidate.profit / routeCandidate.routeTime)
    end

    -- sort by profit
    --local sortFn = function(a, b)
    --    return a.profit > b.profit
    --end

    -- sort by profit per unit time
    local sortFn = function(a, b)
        return a.profit / a.routeTime > b.profit / b.routeTime
    end

    local ret = nil
    table.sort(routes, sortFn)
    for _, routeCandidate in pairs(routes) do
        if not AutoTrader.filterTrade(filterBuy, routeCandidate.buyable, currentCoords) then
            goto continue
        end

        if not AutoTrader.filterTrade(filterSell, routeCandidate.sellable, routeCandidate.buyable.coords) then
            goto continue
        end

        -- TODO: any case where we'd consider buy-only route?
        -- e.g. stockpiling goods
        if routeCandidate.amountToSell <= 0 then
            goto continue
        end

        if AutoTrader.conflictsWithClaims(routeCandidate) then
            goto continue
        end

        ret = routeCandidate
        break
        ::continue::
    end

    return ret
end

-- JumpAI functions
function AutoTrader.finishedJump(ship, ok)
    JumpAI.reset()
    if not ok then
        local x,y = Sector():getCoordinates()

        getParentFaction():sendChatMessage(ship.name, ChatMessageType.Error, "Can't find a jump route for trader in ${x}:${y}"%_T % {x=x,y=y})

        if state == States.TravelToBuy then
            getParentFaction():sendChatMessage(ship.name, ChatMessageType.Normal, "Sir, I can't find a jump path from ${x}:${y} to my trade buy in ${destX}:${destY}"%_T % {x=x,y=y,destX=route.buyable.x,destY=route.buyable.y})
        elseif state == States.TravelToSell then
            getParentFaction():sendChatMessage(ship.name, ChatMessageType.Normal, "Sir, I can't find a jump path from ${x}:${y} to my trade sell in ${destX}:${destY}"%_T % {x=x,y=y,destX=route.sellable.x,destY=route.sellable.y})
        end
        -- TODO: what should we do in this error state?
        state = States.Stuck
    else
        if state == States.TravelToBuy then
            -- TODO: check that our buy is still valid
            print("AutoTrader: buy")
            DockAI.reset()
            state = States.Buy
        elseif state == States.TravelToSell then
            -- TODO: check that our sell is still valid
            print("AutoTrader: sell")
            DockAI.reset()
            state = States.Sell
        else
            print("AutoTrader was in a bad state ${state} for traveling" % {state=state})
        end
    end
end

-- DockAI functions

function AutoTrader.dockAndTrade(timeStep, entity, station)
    if station:hasComponent(ComponentType.DockingPositions) then
        -- dock with the station
        DockAI.updateDockingUndocking(timeStep, station, 5, AutoTrader.doTransaction, AutoTrader.finishedDock)
    else
        -- TODO: I've seen the trader get stuck here

        -- merchant ship, fly close to it, as if we're going to dock
        -- don't use CheckShipDocked from lib/player.lua because it will send
        -- chat message errors
        if station:getNearestDistance(entity) <= 50 then
            -- close enough, do the transaction and we're done
            AutoTrader.doTransaction(entity, station)
            AutoTrader.finishedDock(entity, "Trading is now over")
        else
            -- need to get closer
            ShipAI(entity):setFly(station.translationf, 0)
        end
    end
end

function AutoTrader.doTransaction(ship, station)
    local script
    local invokedFnc
    local amountToTrade
    local good = route.buyable.good.name

    -- TODO: we should make sure the route is up to date
    if state == States.Buy then
        -- when the ship buys, the station sells to the ship
        invokedFnc = "sellToShip"
        script = route.buyable.script

        amountToTrade = route.amountToBuy
    elseif state == States.Sell then
        -- when the ship sells, the station buys from the ship
        invokedFnc = "buyFromShip"
        script = route.sellable.script

        amountToTrade = route.amountToSell
    else
        print("AutoTrader was in a bad state ${state} for docking transaction" % {state=state})
    end

    if invokedFnc then
        local ok, ret = station:invokeFunction(script, invokedFnc, ship.index, good, amountToTrade, true)
        if ok == 0 then
            print("trading ${amount} ${good}" % {amount = amountToTrade, good = good})
        else
            print("error trading goods")
        end
    else
        print("AutoTrader didn't have a script to engage in transaction")
    end
end

-- This function adds optional interaction with TradeBeacons mod from @MrKMG
-- in particular, this will trigger local trade beacons to update trade info
-- e.g. right after we buy or sell a good
function AutoTrader.kickLocalTradeBeacons()
    print("AutoTrader: kicking trade beacons...")
    local beacons = {Sector():getEntitiesByScript("entity/tradebeacon.lua")}
    local parentFaction = getParentFaction()
    for _, beacon in pairs(beacons) do
        print("AutoTrader: kicking beacon %1%", beacon.title)
        if parentFaction.index == beacon.factionIndex then
            local ok, ret = beacon:invokeFunction("entity/tradebeacon.lua", "registerWithPlyer")
            if not ok then
                print("AutoTrader: error kicking %1%", beacon.title)
            end
        end
    end
    print("AutoTrader: done kicking trade beacons.")
end

function AutoTrader.finishedDock(ship, msg)
    DockAI.reset()
    if state == States.Buy then
        -- kick any local trade beacons to update trading data 
        AutoTrader.kickLocalTradeBeacons()

        print("AutoTrader: travel to sell")
        JumpAI.reset()
        state = States.TravelToSell
    elseif state == States.Sell then
        -- kick any local trade beacons to update trading data 
        AutoTrader.kickLocalTradeBeacons()

        print("AutoTrader: done")
        state = States.Done
    else
        print("got unexpected state while finishing AutoTrader transaction")
        state = States.Stuck
    end
end

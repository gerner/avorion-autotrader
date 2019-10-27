package.path = package.path .. ";data/scripts/lib/?.lua"

include("utility")
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

-- rough time to travel to a station, dock, do transaction, undock
-- in terms of jump cooldown
-- this is just an estimate to compare routes in terms of profit/time
local dockingOverheadTime = 3

function AutoTrader.initialize()
    -- kick tradingoverview to get data ready for us
    Entity():invokeFunction("tradingoverview.lua", "getData")
    searchInterval = 0.5
    state = States.Search
end

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
        return 60
    else
        -- frequently update because we're doing active stuff like docking
        return 0.5
    end
end

function AutoTrader.updateServer(timeStep)
    wasInited = true

    local entity = Entity()
    if not entity:hasScript("tradingoverview.lua") then
        ShipAI():setStatus("You have to install a Trading System in the ship for AutoTrader to work."%_T, {})
        Faction():sendChatMessage("", ChatMessageType.Error, "You have to install a Trading System in the ship for Auto Trader to work."%_T)
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

    local foundRoute = AutoTrader.findRoute()
    if foundRoute then
        print("AutoTrader: found a route")
        printTable(foundRoute)
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
    JumpAI.updateJumpToSector(route.buyable.coords.x, route.buyable.coords.y, finishedJump)
end

function AutoTrader.StateBuy(timeStep, entity)
    local station = Sector():getEntity(route.buyable.stationIndex)

    -- TODO: make sure the station still exists and we can do our transaction
    -- TODO: handle merchant ships to which we cannot dock

    ShipAI():setStatus("Buying ${amountToBuy} units of ${good} from ${stationName} in ${x}:${y}"%_T, {amountToBuy = route.amountToBuy, good = route.buyable.good.name, stationName = (route.buyable.station%_t % route.buyable.titleArgs), x=route.buyable.coords.x, y=route.buyable.coords.y})
    DockAI.updateDockingUndocking(timeStep, station, 5, doTransaction, finishedDock)
end

function AutoTrader.StateTravelToSell(timeStep, entity)
    ShipAI():setStatus("Traveling to ${x},${y} to sell ${amountToSell} units of ${good} from ${stationName}"%_T, {x = route.sellable.coords.x, y = route.sellable.coords.y, amountToSell = route.amountToSell, good = route.sellable.good.name, stationName = (route.sellable.station%_t % route.sellable.titleArgs)})
    JumpAI.updateJumpToSector(route.sellable.coords.x, route.sellable.coords.y, finishedJump)
end

function AutoTrader.StateSell(timeStep, entity)
    local station = Sector():getEntity(route.sellable.stationIndex)

    -- TODO: make sure the station still exists and we can do our transaction
    -- TODO: handle merchant ships to which we cannot dock

    ShipAI():setStatus("Selling ${amountToSell} units of ${good} to ${stationName} in ${x}:${y}"%_T, {amountToSell = route.amountToSell, good = route.sellable.good.name, stationName = (route.sellable.station%_t % route.sellable.titleArgs), x=route.sellable.coords.x, y=route.sellable.coords.y})
    DockAI.updateDockingUndocking(timeStep, station, 5, doTransaction, finishedDock)
end

function AutoTrader.StateDone()
    -- kick tradingoverview to get data ready for us
    Entity():invokeFunction("tradingoverview.lua", "getData")

    -- search right away
    searchInterval = 0.5
    state = States.Search
end

-- helpers

function AutoTrader.findRoute()
    local ok, sellable, buyable, routes = Entity():invokeFunction("tradingoverview.lua", "getData")
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
                stock = 0
            }
            table.insert(routes, {buyable = buyable, sellable = sellable})
        end
    end

    local ship = Entity()
    local x, y = Sector():getCoordinates()
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
        routeCandidate.sellDist = JumpAI.estimateRouteLength(Entity(), routeCandidate.buyable.coords.x, routeCandidate.buyable.coords.y, routeCandidate.sellable.coords.x, routeCandidate.buyable.sellable.y)
    end

    -- sort by profit
    local sortFn = function(a, b)
        return a.profit > b.profit
    end

    -- sort by profit per unit time
    -- local sortFn = function(a, b)
    --    -- note we subtract 1 from the distances below because I assume the
    --    -- first jump doesn't have to pay any cooldown overhead
    --    local a_time = 0
    --    if a.amountToBuy > 0 then
    --        a_time = a_time + dockingOverheadTime + math.max(a.buyDist - 1, 0)
    --    else
    --    a_time = a_time + dockingOverheadTime + math.max(a.sellDist - 1, 0)

    --    local b_time = 0
    --    if b.amountToBuy > 0 then
    --        b_time = b_time + dockingOverheadTime + math.max(b.buyDist - 1, 0)
    --    else
    --    b_time = b_time + dockingOverheadTime + math.max(b.sellDist - 1, 0)

    --    return a.profit / a_time > b.profit / b_time
    -- end

    table.sort(routes, sortFn)
    for _, routeCandidate in pairs(routes) do
        if routeCandidate.amountToSell > 0 then
            return routeCandidate
        end
    end

    return nil
end

-- JumpAI functions
function finishedJump(ship, ok)
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
function doTransaction(ship, station)
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
            print("traded ${amount} ${good}" % {amount = amountToTrade, good = good})
        else
            print("error trading goods")
        end
    else
        print("AutoTrader didn't have a script to engage in transaction")
    end
end

function finishedDock(ship, msg)
    print("finished docking: %1%", msg)
    DockAI.reset()
    if state == States.Buy then
        print("AutoTrader: travel to sell")
        JumpAI.reset()
        state = States.TravelToSell
    elseif state == States.Sell then
        print("AutoTrader: done")
        state = States.Done
    else
        print("got unexpected state while finishing AutoTrader transaction")
    end
end

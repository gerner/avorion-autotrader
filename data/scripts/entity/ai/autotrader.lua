package.path = package.path .. ";data/scripts/lib/?.lua"

include("utility")
DockAI = include("entity/ai/dock")
JumpAI = include("entity/ai/jump")

-- Don't remove or alter the following comment, it tells the game the namespace this script lives in. If you remove it, the script will break.
-- namespace AutoTrader 
AutoTrader = {}

States = {
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
local noRouteNotificationTimer = 0

local noRouteNotificationPeriod = 60

function AutoTrader.canContinueAutoTrading()
    if not wasInited then return true end
    -- TODO: what's the stopping condition for auto trading?
    -- return States.Done ~= state
    return true
end

function AutoTrader.getUpdateInterval()
    if not wasInited then
        return 1
    elseif state == States.Search then
        -- periodically search for an updated trade route
        return 15
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
        ShipAI():setStatus("Searching for a trade route /* ship AI status*/"%_T, {})

        local foundRoute = AutoTrader.findRoute()
        if foundRoute then
            route = foundRoute

            -- TODO: we could be a lot smarter about considering our own cargo when choosing a route
            -- check if we have the cargo ourselves
            local selfCargoBay = CargoBay():getCargos()
            local selfCargos = {}

            for tradingGood, amount in pairs(selfCargoBay) do
                selfCargos[tradingGood.name] = amount
            end

            -- TODO: allow buying some stock and combining with our own cargo
            -- TODO: consider cargo space
            if not selfCargos[route.buyable.good.name] or selfCargos[route.buyable.good.name] <= (route.sellable.maxStock - route.sellable.stock) then
                print("AutoTrader: have not enough units of %1%, travel to buy", route.buyable.good.name)
                JumpAI.reset()
                state = States.TravelToBuy
            else
                print("AutoTrader: have %1% units of %2%, travel to sell", selfCargos[route.buyable.good.name], route.buyable.good.name)
                JumpAI.reset()
                state = States.TravelToSell
            end
        else
            print("no trade route found")
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
    elseif state == States.TravelToBuy then
        ShipAI():setStatus("Traveling to ${x},${y} to buy ${good} /* ship AI status*/"%_T, {x = route.buyable.coords.x, y = route.buyable.coords.y, good = route.buyable.good.name})
        JumpAI.updateJumpToSector(route.buyable.coords.x, route.buyable.coords.y, finishedJump)
    elseif state == States.Buy then
        ShipAI():setStatus("Buying ${good} from ${stationName}"%_T, {good = route.buyable.good.name, stationName = (route.buyable.station%_t % route.buyable.titleArgs)})

        local station = Sector():getEntity(route.buyable.stationIndex)
        DockAI.updateDockingUndocking(timeStep, station, 5, doTransaction, finishedDock)
    elseif state == States.TravelToSell then
        ShipAI():setStatus("Traveling to ${x},${y} to sell ${good} /* ship AI status*/"%_T, {x = route.sellable.coords.x, y = route.sellable.coords.y, good = route.sellable.good.name})
        JumpAI.updateJumpToSector(route.buyable.coords.x, route.buyable.coords.y, finishedJump)
    elseif state == States.Sell then
        ShipAI():setStatus("Selling ${good} to ${stationName}"%_T, {good = route.buyable.good.name, stationName = (route.sellable.station%_t % route.sellable.titleArgs)})

        local station = Sector():getEntity(route.sellable.stationIndex)
        DockAI.updateDockingUndocking(timeStep, station, 5, doTransaction, finishedDock)
    elseif state == States.Done then
        -- TODO: just start again?
        print("AutoTrader: search for route")
        state = States.Search
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

function sortRoutesByProfitDesc(a, b)
    local a_volume = math.min(a.buyable.stock, a.sellable.maxStock - a.sellable.stock)
    local a_profit = a_volume * (a.sellable.price - a.buyable.price)
    local b_volume = math.min(b.buyable.stock, b.sellable.maxStock - b.sellable.stock)
    local b_profit = a_volume * (b.sellable.price - b.buyable.price)
    return b_profit < a_profit
end

function AutoTrader.considerRoute(routeCandidate)
    -- skip routes that have zero sellable goods
    if routeCandidate.sellable.maxStock - routeCandidate.sellable.stock <= 0 then
        return false
    end
    return true
end

function AutoTrader.findRoute()
    local ok, sellable, buyable, routes = Entity():invokeFunction("tradingoverview.lua", "getData")
    if not ok then
        print("error communicating with trading overview")
        return nil
    end

    printTable(routes)

    -- most profit (= volume * margin) first
    table.sort(routes, sortRoutesByProfitDesc)
    for _, routeCandidate in pairs(routes) do
        if AutoTrader.considerRoute(routeCandidate) then
            print("found a route")
            printTable(routeCandidate)
            return routeCandidate
        end
    end

    return nil
end

-- JumpAI functions
function finishedJump(ship, ok)
    JumpAI.reset()
    if not ok then
        getParentFaction():sendChatMessage(ship.name, ChatMessageType.Error, "Can't find a route to ${destX}:${destY} from ${x}:${y}"%_T, {destX = destX, destY = destY, x = x, y = y})
    else
        if state == States.TravelToBuy then
            print("AutoTrader: buy")
            DockAI.reset()
            state = States.Buy
        elseif state == States.TravelToSell then
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

        -- TODO: also limit by budget and cargo space
        amountToTrade = math.min(route.buyable.stock, route.sellable.maxStock - route.sellable.stock)
    elseif state == States.Sell then
        -- when the ship sells, the station buys from the ship
        invokedFnc = "buyFromShip"
        script = route.sellable.script

        -- TODO: limit by amount on hand
        amountToTrade = math.min(route.buyable.stock, route.sellable.maxStock - route.sellable.stock)
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

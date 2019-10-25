package.path = package.path .. ";data/scripts/lib/?.lua"

include("utility")
DockAI = include("entity/ai/dock")

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

    print("AutoTrader state is ${s}"%{s = state})
    if     state == States.Search then
        ShipAI():setStatus("Searching for a trade route /* ship AI status*/"%_T, {})

        local foundRoute = AutoTrader.findRoute()
        if foundRoute then
            print("moving forward with route")
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
            if selfCargos[route.buyable.good.name] <= (route.sellable.maxStock - route.sellable.stock) then
                state = States.TravelToBuy
            else
                state = States.TravelToSell
            end
        else
            print("no trade route found")
            -- TODO: periodically notify players
        end
    elseif state == States.TravelToBuy then
        local sector = Sector()
        if vec2(sector:getCoordinates()) == route.buyable.coords then
            print("at buyable location")
            state = States.Buy
        else
            ShipAI():setStatus("Traveling to ${x},${y} to buy ${good} /* ship AI status*/"%_T, {x = route.buyable.coords.x, y = route.buyable.coords.y, good = route.buyable.good.name})
            -- TODO: pathfind to target destination
        end
    elseif state == States.Buy then
        ShipAI():setStatus("Buying ${good} from ${stationName}"%_T, {good = route.buyable.good.name, stationName = (route.buyable.station%_t % route.buyable.titleArgs)})

        local station = Sector():getEntity(route.buyable.stationIndex)
        DockAI.updateDockingUndocking(timeStep, station, 5, doTransaction, finished)
    elseif state == States.TravelToSell then
        local sector = Sector()
        if vec2(sector:getCoordinates()) == route.sellable.coords then
            print("at sellable location")
            state = States.Sell
        else
            ShipAI():setStatus("Traveling to ${x},${y} to sell ${good} /* ship AI status*/"%_T, {x = route.sellable.coords.x, y = route.sellable.coords.y, good = route.sellable.good.name})
            -- TODO: pathfind to target destination
        end
    elseif state == States.Sell then
        ShipAI():setStatus("Selling ${good} to ${stationName}"%_T, {good = route.buyable.good.name, stationName = (route.sellable.station%_t % route.sellable.titleArgs)})

        local station = Sector():getEntity(route.sellable.stationIndex)
        DockAI.updateDockingUndocking(timeStep, station, 5, doTransaction, finished)
    elseif state == States.Done then
        -- TODO: just start again?
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

function AutoTrader.findRoute()
    print("finding a route...")
    local ok, sellable, buyable, routes = Entity():invokeFunction("tradingoverview.lua", "getData")
    if not ok then
        print("error communicating with trading overview")
        return
    end
    table.sort(routes, sortRoutesByProfitDesc)


    -- TODO: handle no or low space left at seller
    if #routes > 0 then
        print("found a route")
        printTable(routes)
        return routes[1]
    end
    return nil
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
        print("AutoTrader was in a bad state ${state} for transaction" % {state=state})
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

function finished()
    DockAI.reset()
    if state == States.Buy then
        print("finished buying, moving to travel")
        state = States.TravelToSell
    elseif state == State.Sell then
        print("finished selling, moving to done")
        state = States.Done
    else
        print("got unexpected state while finishing AutoTrader transaction")
    end
end

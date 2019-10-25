-- Jump Pathfinding, inspired by DockAI (entity/ai/dock.lua)

include("utility")

local JumpAI = {}

function JumpAI.reset()
    ShipAI():stop()
end

function JumpAI.updateJumpToSector(destX, destY, finished)
    local sector = Sector()
    local ship = Entity()
    local x, y = sector:getCoordinates()
    if x == destX and y == destY then
        print("JumpAI made it to destination")
        if finished then finished(ship, true) end
        return true
    else
        local nextX, nextY = computeNextJump(ship, destX, destY, x, y)
        local jumpValid, errMsg = ship:isJumpRouteValid(x, y, nextX, nextY)
        if jumpValid then
            ShipAI:setJump(nextX, nextY)
        else
            -- can't find a path to the destination
            print("${ship} Can't find a route to ${destX}:${destY} from ${x}:${y}", {ship = ship.name, destX = destX, destY = destY, x = x, y = y})
            if finished then finished(ship, false) end
            return false
        end
    end
end

function JumpAI.computeNextJump(ship, destX, destY, x, y)
    -- TODO: is this the actual hyperspace reach? does it include system bonuses?
    local hyperspaceReach = ship.hyperspaceJumpReach

    -- TODO: fancy pathfinding like A* or something to get around rifts
    -- instead, do greedy jumping:
    -- next step will be one hyperspacReach segment toward destination
    local totalDist = distance(vec2(destX, destY), vec2(x, y))
    if hyperspaceReach >= totalDist then
        return destX, destY
    else
        return hyperspaceReach / totalDist * (destX - x) + x, hyperspaceReach / totalDist * (destY - y) + y
    end
end

return JumpAI

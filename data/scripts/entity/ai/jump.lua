-- Jump Pathfinding, inspired by DockAI (entity/ai/dock.lua)
-- the idea is you keep calling JumpAI.updateJumpToSector and it'll pathfind a
-- route to get you there eventually
-- the finished call gets called when either it gives up or you arrive in the
-- final destination

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
        print("JumpAI made it to destination %1%:%2%", destX, destY)
        if finished then finished(ship, true) end
        return true
    elseif ShipAI(ship).state ~= AIState.Jump then
        local nextX, nextY = JumpAI.computeNextJump(ship, destX, destY, x, y)
        local jumpValid, errMsg = ship:isJumpRouteValid(x, y, nextX, nextY)
        if jumpValid then
            print("${ship} jumping ${destX}:${destY} from ${x}:${y} via ${nextX}:${nextY}" % {ship = ship.name, destX = destX, destY = destY, x = x, y = y, nextX=nextX, nextY=nextY})
            ShipAI(ship):setJump(nextX, nextY)
            return true
        else
            -- can't find a path to the destination, could be due to rifts
            print("${ship} Can't find a route to ${destX}:${destY} from ${x}:${y} because of ${errMsg}" % {ship = ship.name, destX = destX, destY = destY, x = x, y = y, errMsg=errMsg})
            if finished then finished(ship, false) end
            return false
        end
    else
        -- in the middle of a jump, just wait for it to finish
        return true
    end
end

function JumpAI.computeNextJump(ship, destX, destY, x, y)
    -- TODO: is this the actual hyperspace reach? does it include system bonuses?
    local hyperspaceReach = ship.hyperspaceJumpReach

    -- TODO: fancy pathfinding like A* or something to get around rifts
    -- instead, do greedy jumping:
    -- next step will be one hyperspacReach segment toward destination
    local totalDist = distance(vec2(destX, destY), vec2(x, y))
    print("JumpAI: hyperspace reach is %1%, total dist is %2%", hyperspaceReach, totalDist)
    if hyperspaceReach >= totalDist then
        print("JumpAI: jumping to final destination %1%:%2%", destX, destY)
        return destX, destY
    else
        local offsetX = hyperspaceReach / totalDist * (destX - x)
        local offsetY = hyperspaceReach / totalDist * (destY - y)

        -- round toward zero to get closest sector to current position
        if(offsetX < 0) then offsetX = math.ceil(offsetX) else offsetX = math.floor(offsetX) end
        if(offsetY < 0) then offsetY = math.ceil(offsetY) else offsetY = math.floor(offsetY) end

        local nextX = x + offsetX
        local nextY = y + offsetY
        print("JumpAI: jumping to intermediate %1%:%2%", nextX, nextY)
        return nextX, nextY
    end
end

-- returns number of jumps
function JumpAI.estimateRouteLength(ship, x, y, destX, destY)
    local hyperspaceReach = ship.hyperspaceJumpReach
    local totalDist = distance(vec2(destX, destY), vec2(x, y))
    return math.floor(totalDist / hyperspaceReach), math.floor(totalDist / hyperspaceReach)
end

return JumpAI

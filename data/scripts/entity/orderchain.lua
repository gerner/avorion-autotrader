OrderChain.registerModdedOrderChain(OrderType.AutoTrader, {
    isFinishedFunction = "autoTraderOrderFinished",
    canEnchainAfter = true,
    onActivateFunction = "startAutoTrader",
    canEnchainAfterCheck = "canEnchainAfterAutoTrader",
});

function OrderChain.addAutoTraderOrder(persistent)
    if onClient() then
        invokeServerFunction("addAutoTraderOder", persistent)
        return
    end

    if callingPlayer then
        local owner, _, player = checkEntityInteractionPermissions(Entity(), AlliancePrivilege.ManageShips)
        if not owner then return end
    end

    if persistent == nil then
        persistent = false
    end

    local order = {action = OrderType.AutoTrader, persistent = persistent}

    if OrderChain.canEnchain(order) then
        OrderChain.enchain(order)
    end
end
callable(OrderChain, "addAutoTraderOrder")

function OrderChain.startAutoTrader()
    Entity():invokeFunction("data/scripts/entity/craftorders.lua", "autoTrader")
end
callable(OrderChain, "startAutoTrader")

function OrderChain.autoTraderOrderFinished(order)
    local persistent = order.persistent
    local entity = Entity()
    if not entity:hasScript("data/scripts/entity/ai/autotrader.lua") then
        return true
    end

    if persistent then
        return false
    end

    local ret, result = entity:invokeFunction("data/scripts/entity/ai/autotrader.lua", "canContinueAutoTrading")
    if ret == 0 and result == true then 
        return false
    end

    entity:removeScript("data/scripts/entity/ai/autotrader.lua")
    return true
end
callable(OrderChain, "autoTraderOrderFinished")

function OrderChain.canEnchainAfterAutoTrader(order)
    return not order.persistent
end

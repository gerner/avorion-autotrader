CraftOrders.registerModdedCraftOrder(OrderType.AutoTrader, {
    title = "Auto Trader",
    callback = "onUserAutoTraderOrder"
})

function CraftOrders.onUserAutoTraderOrder()
    if onClient() then
        invokeServerFunction("onUserAutoTraderOrder")
        ScriptUI():stopInteraction()
        return
    end

    Entity():invokeFunction("data/scripts/entity/orderchain.lua", "clearAllOrders")
    Entity():invokeFunction("data/scripts/entity/orderchain.lua", "addAutoTraderOrder", true)
end
callable(CraftOrders, "onUserAutoTraderOrder")

function CraftOrders.autoTrader()
    if onClient() then
        invokeServerFunction("autoTrader")
        ScriptUI():stopInteraction()
        return
    end

    if checkCaptain() then
        CraftOrders.removeSpecialOrders()

        Entity():addScriptOnce("ai/autotrader.lua")
        return true
    end 
end
callable(CraftOders, "autoTrader")

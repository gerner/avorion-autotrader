include ("ordertypes")

MapCommands.registerModdedMapCommand(OrderType.AutoTrader, {
    tooltip = "Auto Trader",
    icon = "data/textures/icons/autotrader.png",
    callback = "onAutoTraderPressed",
})

function MapCommands.onAutoTraderPressed() 
    MapCommands.clearOrdersIfNecessary()
    MapCommands.enqueueOrder("addAutoTraderOrder")
end

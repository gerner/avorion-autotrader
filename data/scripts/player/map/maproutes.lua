MapRoutes.registerModdedMapRoute(OrderType.AutoTrader, {
    orderDescriptionFunction = "autoTraderDescription",
    pixelIcon = "data/textures/icons/pixel/autoTrader.png",
});

function MapRoutes.autoTraderDescription(order, i, line)
    line.ltext = "[${i}] AutoTrader"%_t % {i = i}
end
callable(MapRoutes, "autoTraderDescription")

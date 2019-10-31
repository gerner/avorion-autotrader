include("stringutility.lua")

RouteSerializer = {}

function RouteSerializer.routeToClaim(entityIndex, route)
    -- claims can be structured, but should be representatble by string interpolation
    return {
        entityIndex = entityIndex,
        goodName = route.buyable.good.name,
        buyIndex = route.buyable.stationIndex,
        amountToBuy = route.amountToBuy,
        sellIndex = route.sellable.stationIndex,
        amountToSell = route.amountToSell
    }
end

function RouteSerializer.serializeClaim(claim)
    -- serialized form is a tab separated string
    return "${entityIndex}\t${goodName}\t${buyIndex}\t${amountToBuy}\t${sellIndex}\t${amountToSell}" % claim
end

function RouteSerializer.deserializeClaim(claimString)
    -- split on tabs
    local entityIndex, goodName, buyIndex, amountToBuy, sellIndex, amountToSell = claimString:split("\t")

    -- reverse string interpolation:
    -- reconstruct objects like UUIDs and numbers
    -- stick in a table
    return {
        entityIndex = Uuid(entityIndex),
        goodName = goodName,
        buyIndex = Uuid(buyIndex),
        amountToBuy = tonumber(amountToBuy),
        sellIndex = Uuid(sellIndex),
        amountToSell = tonumber(amountToSell)
    }
end

function RouteSerializer.serializeClaims(claims)
    local claimArray = {}
    for _, claim in pairs(claims) do
        table.insert(claimArray, serializeClaim(claim))
    end

    return string.join(claimArray, "\n")
end

function RouteSerializer.deserializeClaims(claimsString)
    local claimLines = claimsString:split("\n")
    local claims = {}
    for _, claimString in pairs(claimLines) do
        table.insert(claims, deserializeClaim(claimString))
    end

    return claims
end

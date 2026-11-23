return {
    Enabled = true,
    -- The panel cycles these distances. Only already streamed-in actors can be shown.
    RangesMeters = {60, 120, 240},
    DefaultRangeIndex = 2,
    MaxMarkers = 24,
    -- Panel type filter: all (off), hide confirmed loose money, materials, chests, money, books/pages/letters, memory flowers/petals, the two verified fragments, inactive bells.
    DefaultFilterIndex = 1,
    -- The panel toggles flower/petal sources independently of the type filter.
    ShowMemoryFlowers = true,
    -- Panel count: off, nearest 3, nearest 1. Independent of the type filter.
    DefaultFocusIndex = 1,
    -- The panel toggles relative height; small differences stay hidden.
    ShowHeightDifference = false,
    HeightDifferenceMinMeters = 2,
    -- The panel toggles the single selected target's walking-route preview.
    RouteEnabled = false,
    -- Suppress ordinary markers only while a route target is active.
    RouteOnlyTarget = true,
    FontScale = 1.6,
    HeightOffsetCm = 100,
    ItemColor = {R = 255, G = 235, B = 40, A = 255},
    ChestColor = {R = 70, G = 245, B = 255, A = 255},
}

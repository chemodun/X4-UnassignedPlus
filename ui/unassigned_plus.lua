-- Unassigned Plus
-- Adds an "Unassigned Plus" tab to the Property Owned map-menu panel,
-- placed immediately after the vanilla "Unassigned Ships" tab.
-- A dropdown at the top of the tab lets the player auto-group their unassigned
-- ships into groups by Purpose, Size, Order, or combinations.
--
-- The tab uses the same ship rows as the vanilla unassigned-ships view: it calls
-- menu.createPropertySection for each group, so hull bars, action buttons, and
-- sub-expansion all work exactly as they do in the vanilla tab.
--
-- Compatible with X4 8.00 and 9.00.

local ffi = require("ffi")
local C   = ffi.C

ffi.cdef[[
  typedef uint64_t UniverseID;

  typedef struct {
    int major;
    int minor;
  } GameVersion;

  typedef struct {
    const char* id;
    const char* name;
    const char* description;
    const char* category;
    const char* categoryname;
    bool        infinite;
    uint32_t    requiredSkill;
  } OrderDefinition;

  typedef struct {
    size_t      queueidx;
    const char* state;
    const char* statename;
    const char* orderdef;
    size_t      actualparams;
    bool        enabled;
    bool        isinfinite;
    bool        issyncpointreached;
    bool        istemporder;
  } Order;

  bool        GetDefaultOrder(Order* result, UniverseID controllableid);
  GameVersion GetGameVersion(void);
  bool        GetOrderDefinition(OrderDefinition* result, const char* orderdefid);
  UniverseID  GetPlayerID(void);
]]

-- *** constants ***

local PAGE_ID  = 1972092421
local MODE     = "UnassignedPlus"
local TAB_ICON = "mapst_ol_unassigned"

-- Canonical sort order for each dimension.
local PURPOSE_ORDER = { "fight", "auxiliary", "trade", "mine", "salvage", "build", "neutral" }
local SIZE_ORDER    = { "xs", "s", "m", "l", "xl" }
-- Order sort: alphabetical by order definition id (built dynamically at runtime).
-- We sort order groups alphabetically by name since we can't predict all order IDs.

-- *** module table ***

local usp = {
  menuMap       = nil,
  menuMapConfig = {},
  isV9          = C.GetGameVersion().major >= 9,
  -- Set in Init once the player entity is available.
  playerId      = nil,

  -- Current grouping selection (persists for the game session).
  groupingMode  = "none",

  -- When true, multi-dim groups are rendered as a nested tree of headers.
  hierarchical     = false,
  -- When true, +/- toggle buttons are shown on group headers.
  collapsible      = false,
  -- Per-group collapsed state: [key] = true means the group is collapsed.
  -- Only meaningful when collapsible = true; cleared when checkbox changes.
  groupExpandState = {},
  -- When true, the next render collapses all groups (set when mode changes while all were collapsed).
  collapseAllOnNextRender = false,

  -- Per-ship enrichment data, keyed by tostring(luaId).
  -- Populated by enrichShipData (on_every_playerobject); consumed by buildGroups.
  shipData      = {},

  -- Vanilla "unassignedships" tab entry saved while it is hidden.
  -- nil means the tab is currently visible in propertyCategories.
  hiddenVanillaTab = nil,
}

-- *** debug helpers ***

local debugLevel = "none"   -- "none" | "debug"

local function debug(msg)
  if debugLevel ~= "none" and type(DebugError) == "function" then
    DebugError("UnassignedPlus: " .. msg)
  end
end

-- *** helpers ***

--- Map a numeric classid to a size key using Helper.isComponentClass —
--- the vanilla pattern from menu_map.lua lines 9861-9875.
local function getShipSize(classid)
  if not classid then return "s" end
  if Helper.isComponentClass(classid, "ship_xl") then return "xl"
  elseif Helper.isComponentClass(classid, "ship_l") then return "l"
  elseif Helper.isComponentClass(classid, "ship_m") then return "m"
  elseif Helper.isComponentClass(classid, "ship_xs") then return "xs"
  else return "s" end  -- ship_s (and any unknown)
end

--- Return the 1-based index of val in arr, or 99 when not found.
local function indexOf(arr, val)
  for i, v in ipairs(arr) do
    if v == val then return i end
  end
  return 99
end

-- Lazily-initialised display labels so ReadText runs after the locale is loaded.
local cachedPurposeLabels = nil
local cachedSizeLabels    = nil
-- Order labels are looked up dynamically via GetOrderDefinition; no static table needed.

local function purposeLabels()
  if not cachedPurposeLabels then
    -- Vanilla purpose names from page 20213 "Object Purposes".
    cachedPurposeLabels = {
      fight     = ReadText(20213, 300),
      auxiliary = ReadText(20213, 1500),
      trade     = ReadText(20213, 200),
      mine      = ReadText(20213, 500),
      salvage   = ReadText(20213, 1800),
      build     = ReadText(20213, 400),
      neutral   = ReadText(PAGE_ID, 125),   -- "Other" (no vanilla equivalent)
    }
  end
  return cachedPurposeLabels
end

local function sizeLabels()
  if not cachedSizeLabels then
    cachedSizeLabels = {
      xs = ReadText(PAGE_ID, 130),
      s  = ReadText(PAGE_ID, 131),
      m  = ReadText(PAGE_ID, 132),
      l  = ReadText(PAGE_ID, 133),
      xl = ReadText(PAGE_ID, 134),
    }
  end
  return cachedSizeLabels
end

--- Whether a specific node (by its partial key) is expanded (not collapsed by user).
local function isGroupExpanded(partialKey)
  if not usp.collapsible then return true end
  return usp.groupExpandState[partialKey] ~= false
end

--- Whether a group identified by keyParts[1..depth] is fully visible:
--- all levels 1 through depth must be expanded.
local function isChainVisible(keyParts, depth)
  if not usp.collapsible then return true end
  for l = 1, depth do
    local pk = table.concat(keyParts, "|", 1, l)
    if usp.groupExpandState[pk] == false then return false end
  end
  return true
end

--- Build the dropdown options list (re-read every render pass so locale is correct).
local function getGroupingOptions()
  -- All labels from vanilla texts:
  local dims = {
    { id = "purpose", label = ReadText(1001,  6400)  },  -- "Type"
    { id = "size",    label = ReadText(1001,  8026)  },  -- "Size"
    { id = "order",   label = ReadText(30611, 1304)  },  -- "Order"
    { id = "sector",  label = ReadText(1001,  11284) },  -- "Sector"
  }
  local noneLabel = ReadText(1042, 10011)  -- "None"

  local options = {
    { id = "none", text = noneLabel, icon = "", displayremoveoption = false },
  }

  -- Add all permutations of `chosen` (built so far) with `remaining` dims still to place.
  local function addPerms(chosen, remaining)
    if #remaining == 0 then
      local ids, labels = {}, {}
      for _, d in ipairs(chosen) do
        table.insert(ids,    d.id)
        table.insert(labels, d.label)
      end
      table.insert(options, {
        id                  = table.concat(ids,    "_"),
        text                = table.concat(labels, ", "),
        icon                = "",
        displayremoveoption = false,
      })
      return
    end
    for i = 1, #remaining do
      local rest, nextDim = {}, remaining[i]
      for j, v in ipairs(remaining) do if j ~= i then table.insert(rest, v) end end
      local extendedChosen = {}
      for _, v in ipairs(chosen) do table.insert(extendedChosen, v) end
      table.insert(extendedChosen, nextDim)
      addPerms(extendedChosen, rest)
    end
  end

  -- For each subset size 1..4, enumerate subsets (preserving dim order) then permute.
  local function addSubsets(size, startIdx, current)
    if #current == size then
      addPerms({}, current)
      return
    end
    for i = startIdx, #dims do
      local extendedSubset = {}
      for _, v in ipairs(current) do table.insert(extendedSubset, v) end
      table.insert(extendedSubset, dims[i])
      addSubsets(size, i + 1, extendedSubset)
    end
  end

  for size = 1, #dims do
    addSubsets(size, 1, {})
  end

  return options
end

--- Build a sorted list of { key, label, ships = {LuaID,...} } from unassignedShips.
--- Looks up enrichment data from usp.shipData.
--- Returns nil when groupingMode is "none".
local function buildGroups(unassignedShips)
  local mode = usp.groupingMode
  if mode == "none" then return nil end

  local purposeMap = purposeLabels()
  local sizeMap    = sizeLabels()

  -- Decode mode string into ordered dimension list, e.g. "purpose_size_order" → {"purpose","size","order"}
  local dims = {}
  for d in string.gmatch(mode, "[^_]+") do
    table.insert(dims, d)
  end
  local sorterType = usp.menuMap.propertySorterType
  local sectorInverse = (sorterType == "sectorinverse")
  local sectorDimIdx  = nil  -- which sorts[] position holds the sector value

  local groups     = {}
  local groupIndex = {}

  for _, object in ipairs(unassignedShips) do
    local data = usp.shipData[tostring(object)]
    if not data then goto continue end   -- enrichment missing; skip

    local keys   = {}
    local labels = {}
    local sorts  = {}

    for dimIdx, dim in ipairs(dims) do
      if dim == "purpose" then
        local dimKey = data.purpose
        table.insert(keys,   dimKey)
        table.insert(labels, purposeMap[dimKey] or dimKey)
        table.insert(sorts,  indexOf(PURPOSE_ORDER, dimKey))
      elseif dim == "size" then
        local dimKey = data.size
        table.insert(keys,   dimKey)
        table.insert(labels, sizeMap[dimKey] or dimKey)
        local sizeIdx = indexOf(SIZE_ORDER, dimKey)
        if sorterType ~= "classinverse" and sizeIdx ~= 99 then
          sizeIdx = #SIZE_ORDER + 1 - sizeIdx
        end
        table.insert(sorts,  sizeIdx)
      elseif dim == "order" then
        local dimKey = data.orderid
        table.insert(keys,   dimKey)
        table.insert(labels, data.orderName)
        table.insert(sorts,  data.orderName)
      elseif dim == "sector" then
        local dimKey = data.sectorName
        table.insert(keys,   dimKey)
        table.insert(labels, dimKey)
        table.insert(sorts,  dimKey)
        sectorDimIdx = dimIdx
      end
    end

    local key   = table.concat(keys,   "|")  -- use | to avoid clashing with dim separator
    local label = table.concat(labels, " / ")

    if not groupIndex[key] then
      groupIndex[key] = #groups + 1
      table.insert(groups, {
        key        = key,
        label      = label,
        keyParts   = keys,    -- individual key values per dimension
        labelParts = labels,  -- individual label values per dimension
        ships      = {},
        sorts      = sorts,
      })
    end
    table.insert(groups[groupIndex[key]].ships, object)

    ::continue::
  end

  -- Sort groups: compare element by element in sorts[]; strings sort alphabetically.
  table.sort(groups, function(a, b)
    for i = 1, math.max(#a.sorts, #b.sorts) do
      local aValue = a.sorts[i] or 0
      local bValue = b.sorts[i] or 0
      if aValue ~= bValue then
        if type(aValue) == "number" and type(bValue) == "number" then
          return aValue < bValue
        elseif sectorInverse and i == sectorDimIdx then
          return tostring(aValue) > tostring(bValue)
        else
          return tostring(aValue) < tostring(bValue)
        end
      end
    end
    return false
  end)

  return groups
end

-- *** tab registration ***

function usp.setupTab()
  local cfg        = usp.menuMapConfig
  local categories = cfg and cfg.propertyCategories or nil
  if categories == nil then
    debug("propertyCategories not found in menuMapConfig")
    return
  end

  -- Read saved config to check the hide-original-tab setting.
  local savedCfg   = GetNPCBlackboard(usp.playerId, "$unassignedPlusConfig") or {}
  local shouldHide = savedCfg["hideOriginalTab"] == 1

  -- Scan categories: find our tab (bail if already registered), vanilla tab index,
  -- and the best insertion anchors for our own tab.
  local insertAfter  = nil
  local insertBefore = nil
  local fallbackIdx  = nil
  local vanillaTabIdx = nil
  local alreadyRegistered = false
  local existingIdx = nil
  for i, cat in ipairs(categories) do
    if cat.category == MODE then
      debug("tab already registered")
      alreadyRegistered = true
      existingIdx = i
    end
    if cat.category == "fleets" then
      insertAfter = i
    end
    if cat.category == "unassignedships" then
      vanillaTabIdx = i
      insertAfter   = i
    end
    if cat.category == "inventoryships" then
      insertBefore = i
    end
    if string.sub(cat.category, 1, 10) ~= "custom_tab" then
      fallbackIdx = i
    end
  end

  local newTabConfig = {
    category = MODE,
    name     = ReadText(PAGE_ID, 1),
    icon     = TAB_ICON,
  }
  -- Record whether the vanilla tab was already absent (hidden by another mod).
  -- The options checkbox reads this flag to decide whether to render itself as inactive.
  savedCfg["vanillaTabAlreadyHidden"] = (vanillaTabIdx == nil and usp.hiddenVanillaTab == nil) and 1 or 0
  SetNPCBlackboard(usp.playerId, "$unassignedPlusConfig", savedCfg)

  if shouldHide then
    -- If the vanilla tab is present and the user chose to hide it, remove it now.
    -- Adjust the tracked insertion indices to account for the removed entry.
    if vanillaTabIdx ~= nil then
      usp.hiddenVanillaTab = categories[vanillaTabIdx]
      if alreadyRegistered then
        table.remove(categories, vanillaTabIdx)
      else
        categories[vanillaTabIdx] = newTabConfig
      end
      return
    end
  elseif alreadyRegistered and existingIdx then
    if vanillaTabIdx == nil and usp.hiddenVanillaTab ~= nil then
      table.insert(categories, existingIdx, usp.hiddenVanillaTab)
      usp.hiddenVanillaTab = nil
    end
  else
    local idx = insertAfter or fallbackIdx
    if insertBefore and (not idx or insertBefore <= idx) then
      idx = insertBefore - 1
    end
    if idx then
      table.insert(categories, idx + 1, newTabConfig)
      if vanillaTabIdx == nil and usp.hiddenVanillaTab ~= nil then
        -- The vanilla tab was previously hidden by our mod, restore it now.
        table.insert(categories, idx + 1, usp.hiddenVanillaTab)
        usp.hiddenVanillaTab = nil
      end
    end
  end
end

-- *** per-object enrichment callback ***

--- Fired for every player object during the property-owned loop (before display).
--- For ships, stores purpose/size/order/sector in usp.shipData so buildGroups
--- can run in displayTabData without extra GetComponentData calls.
function usp.enrichShipData(infoTableData, entry, propertyMode)
  if usp.groupingMode == "none" then return end
  if not Helper.isComponentClass(entry.classid, "ship") then return end

  local purpose = entry.purpose
  if not purpose or purpose == "" then purpose = "neutral" end
  local sectorName = entry.sector
  if not sectorName or sectorName == "" then sectorName = "?" end

  local object64         = ConvertIDTo64Bit(entry.id)
  local orderBuffer      = ffi.new("Order")
  local orderDefBuffer   = ffi.new("OrderDefinition")

  local orderid   = "wait"
  local orderName = ReadText(PAGE_ID, 140)  -- "Standby" fallback label
  if C.GetDefaultOrder(orderBuffer, object64) then
    local orderDefId = ffi.string(orderBuffer.orderdef)
    if orderDefId and orderDefId ~= "" then
      orderid = orderDefId
      if C.GetOrderDefinition(orderDefBuffer, orderDefId) then
        local defName = ffi.string(orderDefBuffer.name)
        if defName and defName ~= "" then orderName = defName end
      end
    end
  end

  usp.shipData[tostring(entry.id)] = {
    purpose    = purpose,
    size       = getShipSize(entry.classid),
    orderid    = orderid,
    orderName  = orderName,
    sectorName = sectorName,
  }
end

-- *** display callback ***

--- Fired at the end of createPropertyOwned, after the vanilla unassigned-ships
--- section.  When MODE is active: renders the grouping dropdown followed by
--- ship sections (one section per group, or a flat list when mode = "none").
function usp.displayTabData(numDisplayed, instance, ftable, infoTableData)
  if usp.menuMap.propertyMode ~= MODE then
    return { numdisplayed = numDisplayed }
  end

  local maxIcons  = infoTableData.maxIcons
  local totalCols = 5 + maxIcons
  local cfg       = usp.menuMapConfig
  local rowHeight = cfg.mapRowHeight  or 30
  local fontSize  = cfg.mapFontSize   or Helper.standardFontSize
  local noneText  = "-- " .. ReadText(1001, 34) .. " --"
  local _, groupItemsCount = string.gsub(usp.groupingMode, "_", "")
  local hierarchyLevels = usp.hierarchical and (groupItemsCount + 1) or 0

  -- *** Row 1: "Group by:" label + grouping dropdown ***
  local dropdownRow = ftable:addRow("usp_grouping_dropdown", { fixed = true })
  if usp.isV9 and hierarchyLevels > 0 then
    ftable.columndata[1].width = ftable.columndata[1].width + hierarchyLevels * Helper.standardContainerOffset
    ftable.columndata[#ftable.columndata].width = ftable.columndata[#ftable.columndata].width + hierarchyLevels * Helper.standardContainerOffset
    ftable.columndata[2].width = ftable.columndata[2].width - hierarchyLevels * Helper.standardContainerOffset
    ftable.columndata[3].width = ftable.columndata[3].width - hierarchyLevels * Helper.standardContainerOffset
  end
  dropdownRow[1]:setColSpan(2):createText(
    ReadText(PAGE_ID, 100),
    { halign = "left", titleColor = Color["row_title"], fontsize = fontSize }
  )
  dropdownRow[3]:setColSpan(totalCols - 2):createDropDown(
    getGroupingOptions(),
    {
      startOption = usp.groupingMode,
      active      = true,
      height      = rowHeight,
    }
  ):setTextProperties({ fontsize = fontSize })

  dropdownRow[3].handlers.onDropDownConfirmed = function(_, id)
    usp.menuMap.noupdate = false
    -- If collapsible and every current group is collapsed, preserve that state after mode change.
    if usp.collapsible then
      local currentGroups = buildGroups(infoTableData.unassignedShips)
      if currentGroups and #currentGroups > 0 then
        local allCollapsed = true
        for _, group in ipairs(currentGroups) do
          if usp.groupExpandState[group.key] ~= false then
            allCollapsed = false
            break
          end
        end
        usp.collapseAllOnNextRender = allCollapsed
      end
    end
    usp.groupingMode     = id
    usp.groupExpandState = {}
    usp.menuMap.refreshInfoFrame()
  end
  dropdownRow[3].handlers.onDropDownActivated = function() usp.menuMap.noupdate = true end

  -- *** Row 2: "Hierarchical" label + checkbox (only when grouping is active) ***
  if usp.groupingMode ~= "none" then
    local hierarchicalRow = ftable:addRow("usp_hierarchical_row", { fixed = true })
    hierarchicalRow[1]:setColSpan(2):createText(
      ReadText(PAGE_ID, 102),
      { fontsize = fontSize }
    )
    hierarchicalRow[3]:createCheckBox(usp.hierarchical, { height = rowHeight, width = rowHeight })
    hierarchicalRow[3].handlers.onClick = function(_, checked)
      usp.hierarchical     = checked
      usp.groupExpandState = {}
      usp.menuMap.refreshInfoFrame()
    end
  end

  -- *** Row 3: "Collapsible" label + checkbox (only when grouping is active) ***
  if usp.groupingMode ~= "none" then
    local collapsibleRow = ftable:addRow("usp_collapse_row", { fixed = true })
    collapsibleRow[1]:setColSpan(2):createText(
      ReadText(PAGE_ID, 101),
      { fontsize = fontSize }
    )
    collapsibleRow[3]:createCheckBox(usp.collapsible, { height = rowHeight, width = rowHeight })
    collapsibleRow[3].handlers.onClick = function(_, checked)
      usp.collapsible      = checked
      usp.groupExpandState = {}
      usp.menuMap.refreshInfoFrame()
    end
  end

  -- ── "Grouped" section header (only when grouping is active) ────────────────
  if usp.groupingMode ~= "none" then
    if usp.collapsible then
      -- Determine whether all groups are currently expanded (none collapsed).
      local allExpanded = true
      for _, v in pairs(usp.groupExpandState) do
        if v == false then allExpanded = false; break end
      end
      local grow = ftable:addRow("usp_grouped_header", Helper.headerRowProperties)
      grow[1]:createButton({ width = rowHeight }):setText(allExpanded and "-" or "+", { halign = "center" })
      grow[1].handlers.onClick = function()
        if allExpanded then
          -- Collapse all: mark every known group key as collapsed.
          local groups = buildGroups(infoTableData.unassignedShips)
          if groups then
            for _, group in ipairs(groups) do
              usp.groupExpandState[group.key] = false
            end
          end
        else
          -- Expand all: clear every collapsed entry.
          usp.groupExpandState = {}
        end
        usp.menuMap.refreshInfoFrame()
      end
      grow[2]:setColSpan(totalCols - 1):createText(ReadText(PAGE_ID, 103), Helper.headerRowCenteredProperties)
    else
      local grow = ftable:addRow(false, Helper.headerRowProperties)
      grow[1]:setColSpan(totalCols):createText(ReadText(PAGE_ID, 103), Helper.headerRowCenteredProperties)
    end
  end

  -- ── Ship sections ──────────────────────────────────────────────────────────
  if usp.groupingMode == "none" then
    -- Flat list — identical to the vanilla unassigned ships tab.
    numDisplayed = usp.menuMap.createPropertySection(
      instance, "usp_ships_flat", ftable,
      nil,
      infoTableData.unassignedShips,
      noneText,
      nil, numDisplayed, nil, usp.menuMap.propertySorterType
    )
  else
    local groups  = buildGroups(infoTableData.unassignedShips)
    local numDims = 0
    for _ in string.gmatch(usp.groupingMode, "[^_]+") do numDims = numDims + 1 end

    -- If the previous mode had all groups collapsed, collapse the new groups too.
    if usp.collapseAllOnNextRender and groups then
      usp.collapseAllOnNextRender = false
      for _, group in ipairs(groups) do
        usp.groupExpandState[group.key] = false
      end
    end

    -- Render one group-header row with optional +/- toggle button and left-aligned label.
    -- container: the table or rowGroup to add the row into.
    local function renderGroupHeader(container, partialKey, label, isExpanded)
      local headerRow
      if usp.collapsible then
        headerRow = container:addRow("usp_hdr_" .. partialKey, Helper.headerRowProperties)
        headerRow[1]:createButton({ width = rowHeight }):setText(isExpanded and "-" or "+", { halign = "center" })
        headerRow[1].handlers.onClick = function()
          if isExpanded then
            usp.groupExpandState[partialKey] = false
          else
            usp.groupExpandState[partialKey] = nil
          end
          usp.menuMap.refreshInfoFrame()
        end
        headerRow[2]:setColSpan(totalCols - 1):createText(label, { halign = "left", titleColor = Color["row_title"] })
      else
        headerRow = container:addRow(false, Helper.headerRowProperties)
        headerRow[1]:setColSpan(totalCols):createText(label, { halign = "left", titleColor = Color["row_title"] })
      end
    end

    -- Render ship rows with the given iteration depth for vanilla-style indentation.
    -- iteration=0, container=nil: uses createPropertySection (flat mode, v8 hierarchical).
    -- iteration=0, container set: v9 hierarchical — createPropertyRow into the rowGroup at depth 0.
    -- iteration>0: v8 hierarchical — createPropertyRow with space-indent, no container.
    local function renderShipRows(container, ships, iteration, sectionId)
      if iteration == 0 and container == nil then
        return usp.menuMap.createPropertySection(
          instance, sectionId, ftable,
          nil, ships, noneText,
          nil, numDisplayed, nil, usp.menuMap.propertySorterType
        )
      end
      for _, ship in ipairs(ships) do
        if usp.isV9 then
          numDisplayed = usp.menuMap.createPropertyRow(
            instance, ftable, container, ship, iteration,
            nil, nil, nil, numDisplayed, usp.menuMap.propertySorterType)
        else
          numDisplayed = usp.menuMap.createPropertyRow(
            instance, ftable, ship, iteration,
            nil, nil, nil, numDisplayed, usp.menuMap.propertySorterType)
        end
      end
      return numDisplayed
    end

    if groups and #groups > 0 then
      if usp.hierarchical and numDims > 1 then
        -- ── Hierarchical rendering: nested headers, one level per dimension ──
        -- Each level-N header is indented with (N-1) * 4 spaces, matching vanilla fleet depth.
        -- Collapsing a level-N header hides all deeper headers and ships below it.
        -- v9: each non-top level header is placed inside the parent level's rowGroup,
        --     and ships are placed inside the deepest rowGroup.
        local currentPartials = {}
        local rowGroups = {}  -- v9: [level] = the rowGroup that owns the most-recently-seen group at that level
        for _, group in ipairs(groups) do
          for level = 1, numDims do
            local partialKey = table.concat(group.keyParts, "|", 1, level)
            if currentPartials[level] ~= partialKey then
              currentPartials[level] = partialKey
              for l = level + 1, numDims do currentPartials[l] = nil end
              -- Only show header if all ancestor levels are visible.
              if isChainVisible(group.keyParts, level - 1) then
                -- v9: rowGroup nesting provides visual depth; no manual indent needed.
                -- v8: prepend spaces to simulate indentation.
                local headerLabel = usp.isV9 and group.labelParts[level]
                  or (string.rep("    ", level - 1) .. group.labelParts[level])
                if usp.isV9 then
                  -- Each group gets its OWN new rowGroup; the header is its very first row.
                  -- Rule: once a sub-rowGroup has received rows, the parent can't receive
                  -- more direct rows — the disconnect check fires. But addRowGroup itself
                  -- never triggers the check (only addRow does), and when firstrow==0
                  -- (first-ever addRow on a brand-new group) the check is also skipped.
                  -- So: create group, add header (firstrow=0 → safe), then add sub-groups
                  -- and ship rows while still in this group (previousRow == self.index → safe).
                  -- Level auto-increments through addRowGroup's default logic, giving each
                  -- nesting depth the correct visual indent. Column widths are pre-expanded
                  -- by hierarchyLevels * standardContainerOffset at the top of displayTabData.
                  local parentContainer = (level == 1) and ftable or rowGroups[level - 1]
                  local groupContainer  = parentContainer:addRowGroup({})
                  renderGroupHeader(groupContainer, partialKey, headerLabel, isGroupExpanded(partialKey))
                  rowGroups[level] = groupContainer
                else
                  renderGroupHeader(ftable, partialKey, headerLabel, isGroupExpanded(partialKey))
                end
              end
            end
          end
          -- Ship rows: visible only when the full ancestor chain is expanded.
          -- v9: ships go into rowGroups[numDims] right after its header — no sub-groups
          --     have been added to it yet, so previousRow == self.index → safe.
          -- v8: iteration=numDims prepends spaces to each ship name.
          local shipIteration = usp.isV9 and 0 or numDims
          if isChainVisible(group.keyParts, numDims) then
            numDisplayed = renderShipRows(usp.isV9 and rowGroups[numDims] or nil,
              group.ships, shipIteration, "usp_grp_" .. group.key)
          end
        end
      else
        -- ── Flat rendering: one composite-key header per group ──
        for _, group in ipairs(groups) do
          local groupKey = group.key
          local expanded = isGroupExpanded(groupKey)
          renderGroupHeader(ftable, groupKey, group.label, expanded)
          if expanded then
            numDisplayed = usp.menuMap.createPropertySection(
              instance, "usp_grp_" .. groupKey, ftable,
              nil, group.ships, noneText,
              nil, numDisplayed, nil, usp.menuMap.propertySorterType
            )
          end
        end
      end
    else
      -- No unassigned ships at all.
      local emptyRow = ftable:addRow(false, {})
      emptyRow[1]:setColSpan(totalCols):createText(ReadText(PAGE_ID, 1000))
    end
  end

  return { numdisplayed = numDisplayed }
end

-- *** init ***

local function Init()
  debug("initialising")

  local menuMap = Helper.getMenu("MapMenu")
  if menuMap == nil or type(menuMap.registerCallback) ~= "function" then
    debug("MapMenu not found — kuertee UI Extensions not loaded?")
    return
  end

  usp.menuMap       = menuMap
  usp.menuMapConfig = menuMap.uix_getConfig() or {}
  usp.playerId      = ConvertStringTo64Bit(tostring(C.GetPlayerID()))

  menuMap.registerCallback(
    "createPropertyOwned_on_every_playerobject",
    usp.enrichShipData)
  menuMap.registerCallback(
    "createPropertyOwned_on_createPropertySection_unassignedships",
    usp.displayTabData)

  usp.setupTab()

  RegisterEvent("UnassignedPlus.ConfigChanged", usp.setupTab)
end

Register_OnLoad_Init(Init)

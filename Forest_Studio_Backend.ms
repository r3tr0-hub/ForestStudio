/*
    Генератор леса
    MAXScript для 3ds Max 2020+

    Назначение:
    - посадка экземпляров объектов на террейн по цветовой PNG/TGA-маске;
    - плотность задаётся физически в объектах на гектар;
    - масштаб сцены задаётся явно: сколько scene units соответствует одному игровому метру;
    - альфа-канал маски является множителем локальной плотности;
    - отдельные группы используют разные исходные слои и параметры;
    - позиции генерируются по пространственной сетке с случайным джиттером;
    - поддерживаются минимальные расстояния внутри группы и между группами;
    - опционально учитываются выделенные полигоны Editable Poly;
    - созданные объекты помещаются в слои Forest_<имя исходного слоя>;
    - создание объектов выполняется в одном Undo-блоке;
    - интеграция STALKER SDK: импорт .object через xrTools.ObjectImport.ms, Forest LOD и экспорт scene_object.part.

    Важные API-решения:
    1) LayerProperties.nodes в реальном MAXScript является методом с out-параметром:
       layer.nodes &layerNodes
    2) Для создания именованного слоя используется реальный метод:
       LayerManager.newLayerFromName layerName
    3) Для отдельного системного выбора цвета используется:
       colorPickerDlg
*/

try (destroyDialog forestUI) catch()
try (destroyDialog forestImportUI) catch()
try (destroyDialog forestLodUI) catch()
try (destroyDialog forestExportUI) catch()
try (destroyDialog forestPresetUI) catch()
try (destroyDialog forestLibraryUI) catch()
try
(
    if forestMaskBitmap != undefined do
    (
        close forestMaskBitmap
    )
)
catch()

global FS04_WINDOW
fn forestStudioNotice message title:"Forest Studio" =
(
    if FS04_WINDOW != undefined then
    (
        try (FS04_WINDOW.Notify (message as string) title) catch (messageBox message title:title)
    )
    else messageBox message title:title
    true
)
fn forestStudioAsk message title:"Forest Studio" =
(
    if FS04_WINDOW != undefined then
    (
        try (FS04_WINDOW.Confirm (message as string) title) catch (queryBox message title:title)
    )
    else queryBox message title:title
)

global forestTerrain = undefined
global forestUseSubObj = false
global forestMaskBitmap = undefined
global forestMaskPath = ""
global forestGroupsList = #()
global forestSeed = 1
/*
    Масштаб игрового мира. Для STALKER по умолчанию:
        1 игровой метр = 1.0 единица сцены.
    Значение можно изменить в интерфейсе или взять из System Units 3ds Max.
*/
global forestUnitsPerGameMeter = 1.0
global forestCurrentGroupIndex = 0
global forestDistanceRollout = undefined
global forestDistanceRolloutSerial = 0
global forestUI
global forestRayStartZ = 10000.0

/* STALKER SDK integration */
global forestSDKObjectsRoot = ""
global forestSDKTexturesRoot = ""
global forestObjectImporterScript = ""
global forestLodTextureDir = ""
global forestLastScenePart = ""
global forestImportUI
global forestLodUI
global forestExportUI
global forestPresetUI
global forestPresetCurrentFile = ""
global forestPresetLastName = ""
global forestMemoryLoaded = false
global XRay_ImportModel_rol
global XRay_ImportModel_flo

struct ForestGroup
(
    groupName = "",
    layerName = "",
    color = [255.0, 0.0, 0.0],
    densityPerHa = 300.0,
    scaleMin = 0.8,
    scaleMax = 1.2,
    randomRotY = true,
    alignNormal = true,
    tiltStrength = 5.0,
    distInside = 2.0,
    distToOther = #(),
    sourceObjects = #(),
    presetSourceNames = #(),
    presetSourceRefs = #(),
    sourceWeights = #(), /* relative selection weights 0..100 per ref, default 100 */
    resolvedWeights = #(), /* rebuilt after import; NEVER persisted */
    usePresetSources = false,
    placedPositions = #()
)


/* ------------------------------------------------------------
   БАЗОВЫЕ ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
   ------------------------------------------------------------ */

fn forestGeometryFilter obj =
(
    (obj != undefined) and (superClassOf obj == GeometryClass)
)


fn forestGetLayerNames =
(
    local result = #()

    if LayerManager.count > 0 do
    (
        for i = 0 to (LayerManager.count - 1) do
        (
            local layer = LayerManager.getLayer i
            if layer != undefined do
            (
                append result layer.name
            )
        )
    )

    result
)


fn getObjectsByLayer layerName =
(
    local result = #()
    local layer = LayerManager.getLayerFromName layerName

    if layer != undefined do
    (
        local layerNodes = #()

        try
        (
            if (layer.nodes &layerNodes) do
            (
                for n in layerNodes do
                (
                    if (isValidNode n) and (superClassOf n == GeometryClass) do
                    (
                        append result n
                    )
                )
            )
        )
        catch
        (
            result = #()
        )
    )

    result
)


fn createForestLayer layerName =
(
    local layer = LayerManager.getLayerFromName layerName

    if layer == undefined do
    (
        layer = LayerManager.newLayerFromName layerName
    )

    layer
)


fn getPixelColor bmp x y =
(
    local col = #()

    try
    (
        col = getPixels bmp [x, y] 1
    )
    catch
    (
        col = #()
    )

    if col.count > 0 then
    (
        [col[1].r, col[1].g, col[1].b]
    )
    else
    (
        [0.0, 0.0, 0.0]
    )
)


fn getPixelAlpha bmp x y =
(
    if bmp == undefined then
    (
        0.0
    )
    else
    (
        local bitmapHasAlpha = false

        try
        (
            bitmapHasAlpha = bmp.hasAlpha
        )
        catch
        (
            bitmapHasAlpha = false
        )

        /* Если файл не содержит Alpha, считаем его полностью непрозрачным.
           UI отдельно предупреждает пользователя об отсутствии Alpha. */
        if not bitmapHasAlpha then
        (
            255.0
        )
        else
        (
            local col = #()

            try
            (
                col = getPixels bmp [x, y] 1
            )
            catch
            (
                col = #()
            )

            if col.count > 0 then
            (
                col[1].a
            )
            else
            (
                0.0
            )
        )
    )
)


/* Быстрая диагностика Alpha без полного прохода по многомегапиксельной маске.
   Возвращает #(hasAlpha, minAlpha, maxAlpha, averageAlpha). */
fn forestGetMaskAlphaStats bmp sampleCount:48 =
(
    if bmp == undefined do return #(false, 255.0, 255.0, 255.0)

    local bitmapHasAlpha = false

    try
    (
        bitmapHasAlpha = bmp.hasAlpha
    )
    catch
    (
        bitmapHasAlpha = false
    )

    if not bitmapHasAlpha do return #(false, 255.0, 255.0, 255.0)

    local bmpW = bmp.width
    local bmpH = bmp.height

    if (bmpW <= 0) or (bmpH <= 0) do return #(true, 0.0, 0.0, 0.0)

    if sampleCount < 2 do sampleCount = 2

    local alphaMin = 255.0
    local alphaMax = 0.0
    local alphaSum = 0.0
    local alphaSamples = 0

    for sampleY = 0 to (sampleCount - 1) do
    (
        local fy = (sampleY as float) / ((sampleCount - 1) as float)
        local py = floor (fy * (bmpH - 1))

        for sampleX = 0 to (sampleCount - 1) do
        (
            local fx = (sampleX as float) / ((sampleCount - 1) as float)
            local px = floor (fx * (bmpW - 1))
            local a = getPixelAlpha bmp px py

            if a < alphaMin do alphaMin = a
            if a > alphaMax do alphaMax = a

            alphaSum += a
            alphaSamples += 1
        )
    )

    local alphaAverage = 255.0
    if alphaSamples > 0 do alphaAverage = alphaSum / alphaSamples

    #(true, alphaMin, alphaMax, alphaAverage)
)


fn colorMatch c1 c2 tolerance:10.0 =
(
    ((abs (c1.x - c2.x)) <= tolerance) and
    ((abs (c1.y - c2.y)) <= tolerance) and
    ((abs (c1.z - c2.z)) <= tolerance)
)


fn forestDistanceXY p1 p2 =
(
    local dx = p1.x - p2.x
    local dy = p1.y - p2.y
    sqrt ((dx * dx) + (dy * dy))
)


fn forestSystemUnitsPerMeter =
(
    local oneMeter = 1.0

    try
    (
        oneMeter = units.decodeValue "1m"
    )
    catch
    (
        oneMeter = 1.0
    )

    if oneMeter <= 0.0 do
    (
        oneMeter = 1.0
    )

    oneMeter
)


fn forestSceneUnitsPerMeter =
(
    local oneMeter = forestUnitsPerGameMeter

    if oneMeter <= 0.0 do
    (
        oneMeter = 1.0
    )

    oneMeter
)


fn forestDensityCellSize densityPerHa =
(
    if densityPerHa <= 0.0 then return 0.0

    local oneMeter = forestSceneUnitsPerMeter()
    local cellSizeMeters = sqrt (10000.0 / densityPerHa)

    cellSizeMeters * oneMeter
)


fn forestPointInTriangleXY x y a b c =
(
    local denom = ((b.y - c.y) * (a.x - c.x)) + ((c.x - b.x) * (a.y - c.y))

    if (abs denom) < 0.000001 then
    (
        false
    )
    else
    (
        local u = (((b.y - c.y) * (x - c.x)) + ((c.x - b.x) * (y - c.y))) / denom
        local v = (((c.y - a.y) * (x - c.x)) + ((a.x - c.x) * (y - c.y))) / denom
        local w = 1.0 - u - v
        local eps = -0.00001

        (u >= eps) and (v >= eps) and (w >= eps)
    )
)


fn isPointInSelectedFaces terrain x y =
(
    if not forestUseSubObj then return true
    if terrain == undefined then return true

    local inside = false
    local operationOK = true

    try
    (
        local faceSel = polyop.getFaceSelection terrain

        if faceSel.isEmpty then
        (
            inside = true
        )
        else
        (
            for faceIndex in faceSel while not inside do
            (
                local faceVerts = polyop.getFaceVerts terrain faceIndex

                if (faceVerts != undefined) and (faceVerts.count >= 3) do
                (
                    local v1

                    in coordsys world
                    (
                        v1 = polyop.getVert terrain faceVerts[1]
                    )

                    for j = 2 to (faceVerts.count - 1) while not inside do
                    (
                        local v2
                        local v3

                        in coordsys world
                        (
                            v2 = polyop.getVert terrain faceVerts[j]
                            v3 = polyop.getVert terrain faceVerts[j + 1]
                        )

                        if (v1 != undefined) and (v2 != undefined) and (v3 != undefined) do
                        (
                            if forestPointInTriangleXY x y v1 v2 v3 do
                            (
                                inside = true
                            )
                        )
                    )
                )
            )
        )
    )
    catch
    (
        operationOK = false
    )

    if operationOK then inside else false
)


fn forestRaycastAt x y =
(
    local hit = undefined

    try
    (
        hit = intersectRay forestTerrain (ray [x, y, forestRayStartZ] [0.0, 0.0, -1.0])
    )
    catch
    (
        hit = undefined
    )

    hit
)


/* ------------------------------------------------------------
   РАБОТА С ДИСТАНЦИЯМИ МЕЖДУ ГРУППАМИ
   ------------------------------------------------------------ */

fn forestGetDistanceToOther group targetIndex defaultValue:3.0 =
(
    for item in group.distToOther do
    (
        if item[1] == targetIndex do
        (
            return item[2]
        )
    )

    defaultValue
)


fn forestSetDistance currentIndex targetIndex value =
(
    if (currentIndex < 1) or (currentIndex > forestGroupsList.count) then return false
    if (targetIndex < 1) or (targetIndex > forestGroupsList.count) then return false
    if currentIndex == targetIndex then return false

    local group = forestGroupsList[currentIndex]
    local found = false

    for i = 1 to group.distToOther.count while not found do
    (
        if group.distToOther[i][1] == targetIndex do
        (
            group.distToOther[i] = #(targetIndex, value)
            found = true
        )
    )

    if not found do
    (
        append group.distToOther #(targetIndex, value)
    )

    true
)


fn forestRebuildDistancesAfterDelete deletedIndex =
(
    for gi = 1 to forestGroupsList.count do
    (
        local group = forestGroupsList[gi]
        local rebuilt = #()

        for item in group.distToOther do
        (
            local oldIndex = item[1]
            local distValue = item[2]

            if oldIndex != deletedIndex do
            (
                if oldIndex > deletedIndex then
                (
                    append rebuilt #(oldIndex - 1, distValue)
                )
                else
                (
                    append rebuilt #(oldIndex, distValue)
                )
            )
        )

        group.distToOther = rebuilt
    )
)


/* ------------------------------------------------------------
   ФУНКЦИИ ИНТЕРФЕЙСА
   ------------------------------------------------------------ */

fn forestGroupDisplayName group =
(
    local r = (group.color.x as integer) as string
    local g = (group.color.y as integer) as string
    local b = (group.color.z as integer) as string

    group.groupName + " (" + group.layerName + ") [" + r + "," + g + "," + b + "]"
)


fn forestFindStringIndex items value =
(
    for i = 1 to items.count do
    (
        if items[i] == value do
        (
            return i
        )
    )

    0
)


fn forestSetGroupControlsVisible state =
(
    if forestUI == undefined then return false

    forestUI.gbSettings.visible = state
    forestUI.lblGroupName.visible = state
    forestUI.edtGroupName.visible = state
    forestUI.lblLayer.visible = state
    forestUI.ddlLayer.visible = state
    forestUI.cpColorPicker.visible = state
    forestUI.spnDensity.visible = state
    forestUI.spnScaleMin.visible = state
    forestUI.spnScaleMax.visible = state
    forestUI.chkRandomRot.visible = state
    forestUI.chkAlignNormal.visible = state
    forestUI.spnTilt.visible = state
    forestUI.spnDistInside.visible = state
    forestUI.btnApply.visible = state
    forestUI.srDistances.visible = state

    true
)


fn forestRefreshLayerDropdown =
(
    if forestUI == undefined then return false

    local layerNames = forestGetLayerNames()
    forestUI.ddlLayer.items = layerNames

    true
)


fn forestRefreshDistanceControls =
(
    if forestUI == undefined then return false

    if forestDistanceRollout != undefined do
    (
        try
        (
            removeSubRollout forestUI.srDistances forestDistanceRollout
        )
        catch()

        forestDistanceRollout = undefined
    )

    forestDistanceRolloutSerial += 1

    local rolloutName = "ForestDistancesDynamic_" + (forestDistanceRolloutSerial as string)
    local rc = rolloutCreator rolloutName ""

    rc.begin()

    if (forestCurrentGroupIndex >= 1) and (forestCurrentGroupIndex <= forestGroupsList.count) then
    (
        local currentGroup = forestGroupsList[forestCurrentGroupIndex]
        local addedAny = false

        for i = 1 to forestGroupsList.count do
        (
            if i != forestCurrentGroupIndex do
            (
                addedAny = true

                local ctrlName = ("spnDist_" + (i as string)) as name
                local captionText = forestGroupsList[i].groupName + " (м):"
                local distValue = forestGetDistanceToOther currentGroup i defaultValue:3.0
                local paramText = "range:[0.0,100.0," + (distValue as string) + "] type:#float scale:0.1 fieldWidth:70 align:#right"
                local handlerText = "forestSetDistance forestCurrentGroupIndex " + (i as string) + " val"

                rc.addControl #spinner ctrlName captionText paramStr:paramText
                rc.addHandler ctrlName #changed paramStr:"val" codeStr:handlerText
            )
        )

        if not addedAny do
        (
            rc.addControl #label #lblNoOtherGroups "Других групп пока нет." paramStr:"align:#left"
        )
    )
    else
    (
        rc.addControl #label #lblNoSelectedGroup "Группа не выбрана." paramStr:"align:#left"
    )

    forestDistanceRollout = rc.end()

    if forestDistanceRollout != undefined do
    (
        addSubRollout forestUI.srDistances forestDistanceRollout
    )

    true
)


fn forestLoadGroupToUI index =
(
    if forestUI == undefined then return false

    if (index < 1) or (index > forestGroupsList.count) then
    (
        forestCurrentGroupIndex = 0
        forestSetGroupControlsVisible false
        forestRefreshDistanceControls()
        return false
    )

    forestCurrentGroupIndex = index
    forestSetGroupControlsVisible true
    forestRefreshLayerDropdown()

    local group = forestGroupsList[index]

    forestUI.edtGroupName.text = group.groupName

    local layerIndex = forestFindStringIndex forestUI.ddlLayer.items group.layerName
    forestUI.ddlLayer.selection = layerIndex

    forestUI.cpColorPicker.color = color group.color.x group.color.y group.color.z
    forestUI.spnDensity.value = group.densityPerHa
    forestUI.spnScaleMin.value = group.scaleMin
    forestUI.spnScaleMax.value = group.scaleMax
    forestUI.chkRandomRot.checked = group.randomRotY
    forestUI.chkAlignNormal.checked = group.alignNormal
    forestUI.spnTilt.value = group.tiltStrength
    forestUI.spnDistInside.value = group.distInside

    forestRefreshDistanceControls()

    true
)


fn forestRefreshGroupsList selectIndex:0 =
(
    if forestUI == undefined then return false

    local items = #()

    for group in forestGroupsList do
    (
        append items (forestGroupDisplayName group)
    )

    forestUI.lbGroups.items = items

    if forestGroupsList.count == 0 then
    (
        forestUI.lbGroups.selection = 0
        forestCurrentGroupIndex = 0
        forestSetGroupControlsVisible false
        forestRefreshDistanceControls()
    )
    else
    (
        local wanted = selectIndex

        if wanted < 1 do
        (
            wanted = forestCurrentGroupIndex
        )
        if wanted < 1 do
        (
            wanted = 1
        )
        if wanted > forestGroupsList.count do
        (
            wanted = forestGroupsList.count
        )

        forestUI.lbGroups.selection = wanted
        forestLoadGroupToUI wanted
    )

    true
)


fn forestCreateGroup =
(
    local layerNames = forestGetLayerNames()
    local defaultLayer = ""

    if layerNames.count > 0 do
    (
        defaultLayer = layerNames[1]
    )

    local newIndex = forestGroupsList.count + 1

    local newGroup = ForestGroup \
        groupName:("Группа " + (newIndex as string)) \
        layerName:defaultLayer \
        color:[255.0, 0.0, 0.0] \
        densityPerHa:300.0 \
        scaleMin:0.8 \
        scaleMax:1.2 \
        randomRotY:true \
        alignNormal:true \
        tiltStrength:5.0 \
        distInside:2.0 \
        distToOther:#() \
        sourceObjects:#() \
        presetSourceNames:#() \
        presetSourceRefs:#() \
        usePresetSources:false \
        placedPositions:#()

    for i = 1 to forestGroupsList.count do
    (
        append newGroup.distToOther #(i, 3.0)
        append forestGroupsList[i].distToOther #(newIndex, 3.0)
    )

    append forestGroupsList newGroup
    forestRefreshGroupsList selectIndex:newIndex

    true
)


fn forestDeleteCurrentGroup =
(
    local index = forestCurrentGroupIndex

    if (index < 1) or (index > forestGroupsList.count) then
    (
        forestStudioNotice "Сначала выберите группу для удаления." title:"Генератор леса"
        return false
    )

    deleteItem forestGroupsList index
    forestRebuildDistancesAfterDelete index

    if forestGroupsList.count == 0 then
    (
        forestCurrentGroupIndex = 0
        forestRefreshGroupsList selectIndex:0
    )
    else
    (
        local newIndex = index
        if newIndex > forestGroupsList.count do
        (
            newIndex = forestGroupsList.count
        )
        forestRefreshGroupsList selectIndex:newIndex
    )

    true
)


fn forestApplyCurrentGroupSettings =
(
    local index = forestCurrentGroupIndex

    if (index < 1) or (index > forestGroupsList.count) then
    (
        forestStudioNotice "Группа не выбрана." title:"Генератор леса"
        return false
    )

    if forestUI.spnScaleMin.value > forestUI.spnScaleMax.value then
    (
        forestStudioNotice "Минимальный масштаб не может быть больше максимального." title:"Генератор леса"
        return false
    )

    local group = forestGroupsList[index]
    local oldLayerName = group.layerName

    group.groupName = forestUI.edtGroupName.text

    if (forestUI.ddlLayer.selection >= 1) and (forestUI.ddlLayer.selection <= forestUI.ddlLayer.items.count) then
    (
        group.layerName = forestUI.ddlLayer.items[forestUI.ddlLayer.selection]
    )
    else
    (
        group.layerName = ""
    )

    if group.layerName != oldLayerName do
    (
        group.presetSourceNames = #()
        group.presetSourceRefs = #()
        group.usePresetSources = false
    )

    local chosenColor = forestUI.cpColorPicker.color
    group.color = [chosenColor.r, chosenColor.g, chosenColor.b]

    group.densityPerHa = forestUI.spnDensity.value
    group.scaleMin = forestUI.spnScaleMin.value
    group.scaleMax = forestUI.spnScaleMax.value
    group.randomRotY = forestUI.chkRandomRot.checked
    group.alignNormal = forestUI.chkAlignNormal.checked
    group.tiltStrength = forestUI.spnTilt.value
    group.distInside = forestUI.spnDistInside.value

    forestRefreshGroupsList selectIndex:index

    true
)



/* ------------------------------------------------------------
   ПРЕСЕТЫ И ПАМЯТЬ ГЕНЕРАТОРА
   ------------------------------------------------------------ */

fn forestPresetStorageDir =
(
    local baseDir = ""

    try
    (
        baseDir = getDir #userScripts
    )
    catch
    (
        baseDir = scriptspath
    )

    if (baseDir == undefined) or (baseDir == "") do
    (
        baseDir = scriptspath
    )

    local resultDir = baseDir + "\\ForestGenerator"

    if not doesDirectoryExist resultDir do
    (
        try (makeDir resultDir all:true) catch()
    )

    resultDir
)


fn forestPresetDefaultFile =
(
    (forestPresetStorageDir()) + "\\ForestGenerator_Presets.ini"
)


fn forestMemoryFile =
(
    (forestPresetStorageDir()) + "\\ForestGenerator_Memory.ini"
)


fn forestPresetManagerFile =
(
    (forestPresetStorageDir()) + "\\ForestGenerator_PresetManager.ini"
)


fn forestBoolToString value =
(
    if value then "true" else "false"
)


fn forestStringToBool value defaultValue:false =
(
    if value == "" then
    (
        defaultValue
    )
    else
    (
        (stricmp value "true") == 0
    )
)


fn forestIniFloat fileName sectionName keyName defaultValue =
(
    local textValue = ""
    try (textValue = getINISetting fileName sectionName keyName) catch()

    if textValue == "" then
    (
        defaultValue
    )
    else
    (
        local resultValue = defaultValue
        try (resultValue = textValue as float) catch()
        resultValue
    )
)


fn forestIniInteger fileName sectionName keyName defaultValue =
(
    local textValue = ""
    try (textValue = getINISetting fileName sectionName keyName) catch()

    if textValue == "" then
    (
        defaultValue
    )
    else
    (
        local resultValue = defaultValue
        try (resultValue = textValue as integer) catch()
        resultValue
    )
)


fn forestCurrentSceneFileName =
(
    local resultName = ""

    try
    (
        if maxFileName != "" do
        (
            resultName = maxFilePath + maxFileName
        )
    )
    catch()

    resultName
)


fn forestLoadPresetManagerSettings =
(
    local settingsFile = forestPresetManagerFile()

    if doesFileExist settingsFile do
    (
        local savedFile = ""
        local savedPreset = ""

        try (savedFile = getINISetting settingsFile "preset_manager" "current_file") catch()
        try (savedPreset = getINISetting settingsFile "preset_manager" "last_preset") catch()

        if savedFile != "" do
        (
            forestPresetCurrentFile = savedFile
        )

        if savedPreset != "" do
        (
            forestPresetLastName = savedPreset
        )
    )

    true
)


fn forestSavePresetManagerSettings =
(
    local settingsFile = forestPresetManagerFile()

    try
    (
        setINISetting settingsFile "preset_manager" "current_file" forestPresetCurrentFile forceUTF16:true
        setINISetting settingsFile "preset_manager" "last_preset" forestPresetLastName forceUTF16:true
        true
    )
    catch
    (
        false
    )
)


fn forestActivePresetFile =
(
    if forestPresetCurrentFile != "" then
    (
        forestPresetCurrentFile
    )
    else
    (
        forestPresetDefaultFile()
    )
)


fn forestClearStateSections iniFile baseSection =
(
    if not doesFileExist iniFile then return true

    local oldGroupCount = forestIniInteger iniFile baseSection "groupCount" 0

    for groupIndex = 1 to oldGroupCount do
    (
        try (delINISetting iniFile (baseSection + "_group" + (groupIndex as string))) catch()
    )

    try (delINISetting iniFile baseSection) catch()

    true
)


fn forestFindSourceNode savedName savedRef =
(
    local foundNode = undefined

    if savedRef != "" do
    (
        try (foundNode = forestLibraryFindSourceByRef savedRef) catch()
        if foundNode != undefined do return foundNode
    )

    if savedName != "" do
    (
        try (foundNode = getNodeByName savedName exact:true) catch()
    )

    if (foundNode != undefined) and (isValidNode foundNode) and (superClassOf foundNode == GeometryClass) then
    (
        return foundNode
    )

    foundNode = undefined

    if savedRef != "" do
    (
        /* Библиотека предпочитает проверенный LOD, а не уже посаженный instance. */
        try (foundNode = forestLibraryFindSourceByRef savedRef) catch()
        if foundNode != undefined do return foundNode

        local normalizedRef = ""
        try (normalizedRef = forestNormalizeRefName savedRef) catch (normalizedRef = savedRef)

        for candidate in geometry do
        (
            if foundNode == undefined do
            (
                local candidateRef = ""
                try (candidateRef = forestGetRefName candidate) catch()

                if (candidateRef != "") and ((stricmp candidateRef normalizedRef) == 0) do
                (
                    foundNode = candidate
                )
            )
        )
    )

    foundNode
)


fn forestResolveGroupSourceObjects group =
(
    local result = #()

    if group.usePresetSources and (group.presetSourceNames.count > 0) then
    (
        for sourceIndex = 1 to group.presetSourceNames.count do
        (
            local sourceName = group.presetSourceNames[sourceIndex]
            local sourceRef = ""

            if sourceIndex <= group.presetSourceRefs.count do
            (
                sourceRef = group.presetSourceRefs[sourceIndex]
            )

            local sourceNode = forestFindSourceNode sourceName sourceRef
            if (sourceNode != undefined) and (isValidNode sourceNode) and (superClassOf sourceNode == GeometryClass) do
            (
                append result sourceNode
            )
        )
    )
    else
    (
        result = getObjectsByLayer group.layerName
    )

    result
)


fn forestCommitCurrentGroupUIQuiet =
(
    if forestUI == undefined then return true

    local index = forestCurrentGroupIndex
    if (index < 1) or (index > forestGroupsList.count) then return true

    if forestUI.spnScaleMin.value > forestUI.spnScaleMax.value then return false

    local group = forestGroupsList[index]
    local oldLayerName = group.layerName
    group.groupName = forestUI.edtGroupName.text

    if (forestUI.ddlLayer.selection >= 1) and (forestUI.ddlLayer.selection <= forestUI.ddlLayer.items.count) then
        group.layerName = forestUI.ddlLayer.items[forestUI.ddlLayer.selection]
    else
        group.layerName = ""

    if group.layerName != oldLayerName do
    (
        group.presetSourceNames = #()
        group.presetSourceRefs = #()
        group.usePresetSources = false
    )

    local chosenColor = forestUI.cpColorPicker.color
    group.color = [chosenColor.r, chosenColor.g, chosenColor.b]
    group.densityPerHa = forestUI.spnDensity.value
    group.scaleMin = forestUI.spnScaleMin.value
    group.scaleMax = forestUI.spnScaleMax.value
    group.randomRotY = forestUI.chkRandomRot.checked
    group.alignNormal = forestUI.chkAlignNormal.checked
    group.tiltStrength = forestUI.spnTilt.value
    group.distInside = forestUI.spnDistInside.value

    forestUseSubObj = forestUI.chkUseSubObj.checked
    if forestUI.spnSceneUnits.value > 0.0 do forestUnitsPerGameMeter = forestUI.spnSceneUnits.value

    true
)


fn forestWriteGeneratorState iniFile baseSection includeSources:true groupsOnly:false =
(
    local saveOK = true

    try
    (
        forestClearStateSections iniFile baseSection

        setINISetting iniFile baseSection "formatVersion" "3" forceUTF16:true
        setINISetting iniFile baseSection "stateType" "ForestGenerator" forceUTF16:true
        if not groupsOnly do
        (
            setINISetting iniFile baseSection "sceneFile" (forestCurrentSceneFileName()) forceUTF16:true
            setINISetting iniFile baseSection "terrainName" (if (forestTerrain != undefined) and (isValidNode forestTerrain) then forestTerrain.name else "") forceUTF16:true
            setINISetting iniFile baseSection "maskPath" forestMaskPath forceUTF16:true
            setINISetting iniFile baseSection "useSubObject" (forestBoolToString forestUseSubObj) forceUTF16:true
            setINISetting iniFile baseSection "unitsPerGameMeter" (forestUnitsPerGameMeter as string) forceUTF16:true
            setINISetting iniFile baseSection "seed" (forestSeed as string) forceUTF16:true
        )
        setINISetting iniFile baseSection "groupCount" (forestGroupsList.count as string) forceUTF16:true
        setINISetting iniFile baseSection "selectedGroup" (forestCurrentGroupIndex as string) forceUTF16:true

        for groupIndex = 1 to forestGroupsList.count do
        (
            local group = forestGroupsList[groupIndex]
            local sectionName = baseSection + "_group" + (groupIndex as string)

            setINISetting iniFile sectionName "groupName" group.groupName forceUTF16:true
            setINISetting iniFile sectionName "layerName" group.layerName forceUTF16:true
            setINISetting iniFile sectionName "colorR" (group.color.x as string) forceUTF16:true
            setINISetting iniFile sectionName "colorG" (group.color.y as string) forceUTF16:true
            setINISetting iniFile sectionName "colorB" (group.color.z as string) forceUTF16:true
            setINISetting iniFile sectionName "densityPerHa" (group.densityPerHa as string) forceUTF16:true
            setINISetting iniFile sectionName "scaleMin" (group.scaleMin as string) forceUTF16:true
            setINISetting iniFile sectionName "scaleMax" (group.scaleMax as string) forceUTF16:true
            setINISetting iniFile sectionName "randomRotY" (forestBoolToString group.randomRotY) forceUTF16:true
            setINISetting iniFile sectionName "alignNormal" (forestBoolToString group.alignNormal) forceUTF16:true
            setINISetting iniFile sectionName "tiltStrength" (group.tiltStrength as string) forceUTF16:true
            setINISetting iniFile sectionName "distInside" (group.distInside as string) forceUTF16:true

            for targetIndex = 1 to forestGroupsList.count do
            (
                if targetIndex != groupIndex do
                (
                    local distanceValue = forestGetDistanceToOther group targetIndex defaultValue:3.0
                    setINISetting iniFile sectionName ("distanceTo_" + (targetIndex as string)) (distanceValue as string) forceUTF16:true
                )
            )

            if includeSources then
            (
                if group.usePresetSources and (group.presetSourceNames.count > 0) then
                (
                    setINISetting iniFile sectionName "sourceCount" (group.presetSourceNames.count as string) forceUTF16:true

                    for sourceIndex = 1 to group.presetSourceNames.count do
                    (
                        local sourceRef = ""
                        if sourceIndex <= group.presetSourceRefs.count do sourceRef = group.presetSourceRefs[sourceIndex]

                        setINISetting iniFile sectionName ("source_" + (sourceIndex as string) + "_name") group.presetSourceNames[sourceIndex] forceUTF16:true
                        setINISetting iniFile sectionName ("source_" + (sourceIndex as string) + "_ref") sourceRef forceUTF16:true
                        local weightVal = if sourceIndex <= group.sourceWeights.count then group.sourceWeights[sourceIndex] else 100.0
                        setINISetting iniFile sectionName ("source_" + (sourceIndex as string) + "_weight") (weightVal as string) forceUTF16:true
                    )
                )
                else
                (
                    local sourceNodes = getObjectsByLayer group.layerName
                    setINISetting iniFile sectionName "sourceCount" (sourceNodes.count as string) forceUTF16:true

                    for sourceIndex = 1 to sourceNodes.count do
                    (
                        local sourceNode = sourceNodes[sourceIndex]
                        local sourceRef = ""
                        try (sourceRef = forestGetRefName sourceNode) catch()

                        setINISetting iniFile sectionName ("source_" + (sourceIndex as string) + "_name") sourceNode.name forceUTF16:true
                        setINISetting iniFile sectionName ("source_" + (sourceIndex as string) + "_ref") sourceRef forceUTF16:true
                        local weightVal = if sourceIndex <= group.sourceWeights.count then group.sourceWeights[sourceIndex] else 100.0
                        setINISetting iniFile sectionName ("source_" + (sourceIndex as string) + "_weight") (weightVal as string) forceUTF16:true
                    )
                )
            )
            else
            (
                setINISetting iniFile sectionName "sourceCount" "0" forceUTF16:true
            )
        )
    )
    catch
    (
        format "Forest Generator preset save error: %\n" (getCurrentException())
        saveOK = false
    )

    saveOK
)


fn forestRestoreMaskFromPath savedMaskPath =
(
    if savedMaskPath == "" then return false
    if not doesFileExist savedMaskPath then return false

    local restoredBitmap = undefined

    try
    (
        restoredBitmap = openBitmap savedMaskPath
    )
    catch
    (
        restoredBitmap = undefined
    )

    if restoredBitmap == undefined then return false

    try
    (
        if forestMaskBitmap != undefined do close forestMaskBitmap
    )
    catch()

    forestMaskBitmap = restoredBitmap
    forestMaskPath = savedMaskPath

    true
)


fn forestReadGeneratorState iniFile baseSection restoreSources:true restoreAssets:true quiet:false groupsOnly:false =
(
    if not doesFileExist iniFile then
    (
        if not quiet do forestStudioNotice ("Файл не найден:\n" + iniFile) title:"Генератор леса — пресеты"
        return false
    )

    local groupCountText = ""
    try (groupCountText = getINISetting iniFile baseSection "groupCount") catch()

    if groupCountText == "" then
    (
        if not quiet do forestStudioNotice ("В секции \"" + baseSection + "\" нет сохранённого состояния генератора.") title:"Генератор леса — пресеты"
        return false
    )

    local groupCount = 0
    try (groupCount = groupCountText as integer) catch (groupCount = 0)

    local warningText = ""
    local restoredGroups = #()

    if not groupsOnly do
    (
        local savedUseSub = ""
        try (savedUseSub = getINISetting iniFile baseSection "useSubObject") catch()
        forestUseSubObj = forestStringToBool savedUseSub defaultValue:false
        forestUnitsPerGameMeter = forestIniFloat iniFile baseSection "unitsPerGameMeter" 1.0
        forestSeed = forestIniInteger iniFile baseSection "seed" 1
    )

    for groupIndex = 1 to groupCount do
    (
        local sectionName = baseSection + "_group" + (groupIndex as string)
        local savedGroupName = ""
        local savedLayerName = ""
        local savedRandomRot = ""
        local savedAlignNormal = ""

        try (savedGroupName = getINISetting iniFile sectionName "groupName") catch()
        try (savedLayerName = getINISetting iniFile sectionName "layerName") catch()
        try (savedRandomRot = getINISetting iniFile sectionName "randomRotY") catch()
        try (savedAlignNormal = getINISetting iniFile sectionName "alignNormal") catch()

        if savedGroupName == "" do savedGroupName = "Группа " + (groupIndex as string)

        local restoredGroup = ForestGroup \
            groupName:savedGroupName \
            layerName:savedLayerName \
            color:[ \
                (forestIniFloat iniFile sectionName "colorR" 255.0), \
                (forestIniFloat iniFile sectionName "colorG" 0.0), \
                (forestIniFloat iniFile sectionName "colorB" 0.0) \
            ] \
            densityPerHa:(forestIniFloat iniFile sectionName "densityPerHa" 300.0) \
            scaleMin:(forestIniFloat iniFile sectionName "scaleMin" 0.8) \
            scaleMax:(forestIniFloat iniFile sectionName "scaleMax" 1.2) \
            randomRotY:(forestStringToBool savedRandomRot defaultValue:true) \
            alignNormal:(forestStringToBool savedAlignNormal defaultValue:true) \
            tiltStrength:(forestIniFloat iniFile sectionName "tiltStrength" 5.0) \
            distInside:(forestIniFloat iniFile sectionName "distInside" 2.0) \
            distToOther:#() \
            sourceObjects:#() \
            presetSourceNames:#() \
            presetSourceRefs:#() \
            sourceWeights:#() \
            resolvedWeights:#() \
            usePresetSources:false \
            placedPositions:#()

        for targetIndex = 1 to groupCount do
        (
            if targetIndex != groupIndex do
            (
                local distanceValue = forestIniFloat iniFile sectionName ("distanceTo_" + (targetIndex as string)) 3.0
                append restoredGroup.distToOther #(targetIndex, distanceValue)
            )
        )

        if restoreSources do
        (
            local sourceCount = forestIniInteger iniFile sectionName "sourceCount" 0
            local restoredSources = #()
            local savedSourceNames = #()
            local savedSourceRefs = #()
            local savedSourceWeights = #()
            local targetLayer = undefined

            if savedLayerName != "" do
            (
                targetLayer = LayerManager.getLayerFromName savedLayerName

                if (targetLayer == undefined) and (sourceCount > 0) do
                (
                    try (targetLayer = LayerManager.newLayerFromName savedLayerName) catch()
                )
            )

            for sourceIndex = 1 to sourceCount do
            (
                local savedName = ""
                local savedRef = ""
                try (savedName = getINISetting iniFile sectionName ("source_" + (sourceIndex as string) + "_name")) catch()
                try (savedRef = getINISetting iniFile sectionName ("source_" + (sourceIndex as string) + "_ref")) catch()

                append savedSourceNames savedName
                append savedSourceRefs savedRef
                append savedSourceWeights (amin 100.0 (amax 0.0 (forestIniFloat iniFile sectionName ("source_" + (sourceIndex as string) + "_weight") 100.0)))

                local restoredNode = forestFindSourceNode savedName savedRef

                if (restoredNode != undefined) and (isValidNode restoredNode) then
                (
                    append restoredSources restoredNode

                    if targetLayer != undefined do
                    (
                        try (targetLayer.addNode restoredNode) catch()
                    )
                )
                else
                (
                    warningText += "Не найден источник группы \"" + savedGroupName + "\": " + savedName
                    if savedRef != "" do warningText += " | " + savedRef
                    warningText += "\n"
                )
            )

            restoredGroup.sourceObjects = restoredSources
            restoredGroup.presetSourceNames = savedSourceNames
            restoredGroup.presetSourceRefs = savedSourceRefs
            restoredGroup.sourceWeights = savedSourceWeights
            restoredGroup.usePresetSources = (savedSourceNames.count > 0)
        )

        append restoredGroups restoredGroup
    )

    forestGroupsList = restoredGroups

    local selectedIndex = forestIniInteger iniFile baseSection "selectedGroup" 1
    if forestGroupsList.count == 0 then
    (
        forestCurrentGroupIndex = 0
    )
    else
    (
        if selectedIndex < 1 do selectedIndex = 1
        if selectedIndex > forestGroupsList.count do selectedIndex = forestGroupsList.count
        forestCurrentGroupIndex = selectedIndex
    )

    if restoreAssets and (not groupsOnly) do
    (
        local terrainName = ""
        local savedMaskPath = ""
        try (terrainName = getINISetting iniFile baseSection "terrainName") catch()
        try (savedMaskPath = getINISetting iniFile baseSection "maskPath") catch()

        forestTerrain = undefined

        if terrainName != "" do
        (
            local restoredTerrain = undefined
            try (restoredTerrain = getNodeByName terrainName exact:true) catch()

            if (restoredTerrain != undefined) and (isValidNode restoredTerrain) then
            (
                forestTerrain = restoredTerrain
            )
            else
            (
                warningText += "Не найден террейн: " + terrainName + "\n"
            )
        )

        if savedMaskPath != "" then
        (
            if not (forestRestoreMaskFromPath savedMaskPath) do
            (
                forestMaskPath = savedMaskPath
                warningText += "Не удалось открыть маску: " + savedMaskPath + "\n"
            )
        )
        else
        (
            try
            (
                if forestMaskBitmap != undefined do close forestMaskBitmap
            )
            catch()

            forestMaskBitmap = undefined
            forestMaskPath = ""
        )
    )

    if (warningText != "") and (not quiet) do
    (
        forestStudioNotice ("Состояние загружено, но есть предупреждения:\n\n" + warningText) title:"Генератор леса — пресеты"
    )

    true
)


fn forestSyncMainUIFromGlobals =
(
    if forestUI == undefined then return false

    if (forestTerrain != undefined) and (isValidNode forestTerrain) then
        forestUI.edtTerrain.text = forestTerrain.name
    else
        forestUI.edtTerrain.text = ""

    forestUI.chkUseSubObj.checked = forestUseSubObj
    forestUI.spnSceneUnits.value = forestUnitsPerGameMeter

    if forestMaskBitmap != undefined then
    (
        local maskDisplayName = forestMaskPath
        if maskDisplayName != "" do maskDisplayName = filenameFromPath maskDisplayName
        if maskDisplayName == "" do maskDisplayName = "Маска из памяти"

        forestUI.lblMaskInfo.text = maskDisplayName + " — " + \
            (forestMaskBitmap.width as string) + " x " + \
            (forestMaskBitmap.height as string)

        local alphaStats = forestGetMaskAlphaStats forestMaskBitmap sampleCount:32
        if alphaStats[1] then
        (
            forestUI.lblAlphaInfo.text = "Alpha: ДА | sampled min=" + \
                ((alphaStats[2] as integer) as string) + \
                " max=" + ((alphaStats[3] as integer) as string) + \
                " avg=" + ((alphaStats[4] as integer) as string)
        )
        else
        (
            forestUI.lblAlphaInfo.text = "Alpha: НЕТ — плотность по Alpha не работает"
        )

        forestUI.btnEyedropper.enabled = true
    )
    else
    (
        forestUI.lblMaskInfo.text = if forestMaskPath != "" then ("Маска не найдена: " + filenameFromPath forestMaskPath) else "Маска не загружена"
        forestUI.lblAlphaInfo.text = "Alpha: —"
        forestUI.btnEyedropper.enabled = false
    )

    forestRefreshLayerDropdown()
    forestRefreshGroupsList selectIndex:forestCurrentGroupIndex

    true
)


fn forestPresetNames =
(
    local presetFile = forestActivePresetFile()
    local result = #()

    if doesFileExist presetFile do
    (
        local sections = #()
        try (sections = getINISetting presetFile) catch (sections = #())

        for sectionName in sections do
        (
            local groupCountValue = ""
            try (groupCountValue = getINISetting presetFile sectionName "groupCount") catch()

            if groupCountValue != "" do
            (
                append result sectionName
            )
        )
    )

    try (sort result) catch()
    result
)


fn forestSaveNamedPreset presetName =
(
    if presetName == "" then
    (
        forestStudioNotice "Введите имя пресета." title:"Генератор леса — пресеты"
        return false
    )

    if ((findString presetName "[") != undefined) or ((findString presetName "]") != undefined) then
    (
        forestStudioNotice "В имени пресета нельзя использовать символы [ и ]." title:"Генератор леса — пресеты"
        return false
    )

    if not (forestCommitCurrentGroupUIQuiet()) then
    (
        forestStudioNotice "Минимальный масштаб не может быть больше максимального." title:"Генератор леса — пресеты"
        return false
    )

    local presetFile = forestActivePresetFile()
    local saveOK = forestWriteGeneratorState presetFile presetName includeSources:true

    if saveOK do
    (
        forestPresetLastName = presetName
        forestSavePresetManagerSettings()
        forestSaveMemoryState quiet:true
    )

    saveOK
)


fn forestApplyNamedPreset presetName =
(
    if presetName == "" then return false

    local presetFile = forestActivePresetFile()
    local loadOK = forestReadGeneratorState presetFile presetName restoreSources:true restoreAssets:true quiet:false

    if loadOK do
    (
        forestPresetLastName = presetName
        forestSavePresetManagerSettings()
        forestSyncMainUIFromGlobals()
        forestSaveMemoryState quiet:true
    )

    loadOK
)


fn forestDeleteNamedPreset presetName =
(
    if presetName == "" then return false

    local presetFile = forestActivePresetFile()
    if not doesFileExist presetFile then return false

    forestClearStateSections presetFile presetName

    if forestPresetLastName == presetName do
    (
        forestPresetLastName = ""
        forestSavePresetManagerSettings()
    )

    true
)


fn forestSaveMemoryState quiet:true =
(
    local memoryFile = forestMemoryFile()
    local saveOK = forestWriteGeneratorState memoryFile "ForestGeneratorMemory" includeSources:true

    if (not saveOK) and (not quiet) do
    (
        forestStudioNotice "Не удалось сохранить автопамять генератора." title:"Генератор леса — память"
    )

    saveOK
)


fn forestLoadMemoryState quiet:true forceLoad:false =
(
    local memoryFile = forestMemoryFile()

    if not doesFileExist memoryFile then return false

    if not forceLoad do
    (
        local savedScene = ""
        try (savedScene = getINISetting memoryFile "ForestGeneratorMemory" "sceneFile") catch()
        local currentScene = forestCurrentSceneFileName()

        local sceneMatches = false

        if (savedScene == "") and (currentScene == "") then
        (
            local savedTerrainName = ""
            try (savedTerrainName = getINISetting memoryFile "ForestGeneratorMemory" "terrainName") catch()

            if savedTerrainName != "" do
            (
                local sameTerrain = undefined
                try (sameTerrain = getNodeByName savedTerrainName exact:true) catch()
                sceneMatches = ((sameTerrain != undefined) and (isValidNode sameTerrain))
            )
        )
        else if (savedScene != "") and (currentScene != "") then
        (
            sceneMatches = ((stricmp savedScene currentScene) == 0)
        )

        if not sceneMatches then return false
    )

    local loadOK = forestReadGeneratorState memoryFile "ForestGeneratorMemory" restoreSources:true restoreAssets:true quiet:quiet
    if loadOK do forestMemoryLoaded = true

    loadOK
)


fn forestClearMemoryState =
(
    local memoryFile = forestMemoryFile()

    if doesFileExist memoryFile do
    (
        try (deleteFile memoryFile) catch()
    )

    forestMemoryLoaded = false
    true
)


fn forestPresetRefreshUI =
(
    if forestPresetUI == undefined then return false

    local presetFile = forestActivePresetFile()
    local names = forestPresetNames()

    forestPresetUI.lblPresetFile.text = "INI: " + presetFile

    if names.count > 0 then
    (
        forestPresetUI.ddlPresets.items = names

        local selectedIndex = forestFindStringIndex names forestPresetLastName
        if selectedIndex < 1 do selectedIndex = 1

        forestPresetUI.ddlPresets.selection = selectedIndex
        forestPresetUI.edtPresetName.text = names[selectedIndex]
    )
    else
    (
        forestPresetUI.ddlPresets.items = #("<нет пресетов>")
        forestPresetUI.ddlPresets.selection = 1

        if forestPresetUI.edtPresetName.text == "" do
        (
            forestPresetUI.edtPresetName.text = "Новый пресет"
        )
    )

    local memoryFile = forestMemoryFile()
    forestPresetUI.lblMemory.text = if doesFileExist memoryFile then \
        ("Автопамять: есть | " + filenameFromPath memoryFile) else \
        "Автопамять: пока не сохранена"

    true
)



/* ------------------------------------------------------------
   ВАЛИДАЦИЯ И ГЕНЕРАЦИЯ
   ------------------------------------------------------------ */

fn forestValidateInputs =
(
    if (forestTerrain == undefined) or (not isValidNode forestTerrain) then
    (
        forestStudioNotice "Не выбран корректный объект террейна." title:"Генератор леса"
        return false
    )

    if forestMaskBitmap == undefined then
    (
        forestStudioNotice "Не загружена маска PNG/TGA." title:"Генератор леса"
        return false
    )

    if forestGroupsList.count == 0 then
    (
        forestStudioNotice "Создайте хотя бы одну группу." title:"Генератор леса"
        return false
    )

    if forestUnitsPerGameMeter <= 0.0 then
    (
        forestStudioNotice "Масштаб сцены должен быть больше нуля: 1 игровой метр = X units." title:"Генератор леса"
        return false
    )

    if (forestMaskBitmap.width < 1) or (forestMaskBitmap.height < 1) then
    (
        forestStudioNotice "Маска имеет некорректный размер." title:"Генератор леса"
        return false
    )

    if forestUseSubObj do
    (
        local subObjectOK = true

        try
        (
            local testSelection = polyop.getFaceSelection forestTerrain
        )
        catch
        (
            subObjectOK = false
        )

        if not subObjectOK then
        (
            forestStudioNotice "Use SubObject требует террейн, совместимый с polyop.getFaceSelection, например Editable Poly." title:"Генератор леса"
            return false
        )
    )

    for i = 1 to forestGroupsList.count do
    (
        local group = forestGroupsList[i]

        if (group.layerName == "") and (not group.usePresetSources) then
        (
            forestStudioNotice ("У группы \"" + group.groupName + "\" не выбран слой-источник.") title:"Генератор леса"
            return false
        )

        local sourceObjects = forestResolveGroupSourceObjects group

        if sourceObjects.count == 0 then
        (
            forestStudioNotice ("У группы \"" + group.groupName + "\" не найдено ни одного исходного объекта. Проверьте слой или содержимое пресета.") title:"Генератор леса"
            return false
        )

        if group.scaleMin > group.scaleMax then
        (
            forestStudioNotice ("У группы \"" + group.groupName + "\" минимальный масштаб больше максимального.") title:"Генератор леса"
            return false
        )

        if group.densityPerHa <= 0.0 then
        (
            forestStudioNotice ("У группы \"" + group.groupName + "\" плотность должна быть больше нуля.") title:"Генератор леса"
            return false
        )
    )

    true
)


fn forestGetSpatialBucketIndex x y minX minY bucketSize bucketCols bucketRows =
(
    if bucketSize <= 0.0 then return 0

    local bucketX = floor ((x - minX) / bucketSize)
    local bucketY = floor ((y - minY) / bucketSize)

    if bucketX < 0 do bucketX = 0
    if bucketY < 0 do bucketY = 0
    if bucketX >= bucketCols do bucketX = bucketCols - 1
    if bucketY >= bucketRows do bucketY = bucketRows - 1

    ((bucketY * bucketCols) + bucketX + 1) as integer
)


fn forestGetRequiredDistance currentGroupIndex otherGroupIndex =
(
    if (currentGroupIndex < 1) or (currentGroupIndex > forestGroupsList.count) then return 0.0

    local currentGroup = forestGroupsList[currentGroupIndex]
    local distanceMeters = 0.0

    if currentGroupIndex == otherGroupIndex then
    (
        distanceMeters = currentGroup.distInside
    )
    else
    (
        distanceMeters = forestGetDistanceToOther currentGroup otherGroupIndex defaultValue:0.0
    )

    /* Параметры дистанции в UI задаются в игровых метрах. */
    distanceMeters * forestSceneUnitsPerMeter()
)


fn forestPositionAllowedSpatial currentGroupIndex hitPos spatialBuckets bucketCols bucketRows bucketSize minX minY =
(
    if bucketSize <= 0.0 then return true

    local centerX = floor ((hitPos.x - minX) / bucketSize)
    local centerY = floor ((hitPos.y - minY) / bucketSize)

    if centerX < 0 do centerX = 0
    if centerY < 0 do centerY = 0
    if centerX >= bucketCols do centerX = bucketCols - 1
    if centerY >= bucketRows do centerY = bucketRows - 1

    local minBX = centerX - 1
    local maxBX = centerX + 1
    local minBY = centerY - 1
    local maxBY = centerY + 1

    if minBX < 0 do minBX = 0
    if minBY < 0 do minBY = 0
    if maxBX >= bucketCols do maxBX = bucketCols - 1
    if maxBY >= bucketRows do maxBY = bucketRows - 1

    for bucketY = minBY to maxBY do
    (
        for bucketX = minBX to maxBX do
        (
            local bucketIndex = ((bucketY * bucketCols) + bucketX + 1) as integer
            local bucket = spatialBuckets[bucketIndex]

            if bucket != undefined do
            (
                for entry in bucket do
                (
                    local otherGroupIndex = entry[1]
                    local otherPositionIndex = entry[2]
                    local requiredDistance = forestGetRequiredDistance currentGroupIndex otherGroupIndex

                    if requiredDistance > 0.0 do
                    (
                        if (otherGroupIndex >= 1) and (otherGroupIndex <= forestGroupsList.count) do
                        (
                            local otherGroup = forestGroupsList[otherGroupIndex]

                            if (otherPositionIndex >= 1) and (otherPositionIndex <= otherGroup.placedPositions.count) do
                            (
                                local otherPos = otherGroup.placedPositions[otherPositionIndex]

                                if (forestDistanceXY otherPos hitPos) < requiredDistance do
                                (
                                    return false
                                )
                            )
                        )
                    )
                )
            )
        )
    )

    true
)


fn forestSpatialAddPosition groupIndex positionIndex hitPos spatialBuckets bucketCols bucketRows bucketSize minX minY =
(
    local bucketIndex = forestGetSpatialBucketIndex hitPos.x hitPos.y minX minY bucketSize bucketCols bucketRows

    if bucketIndex < 1 then return false

    local bucket = spatialBuckets[bucketIndex]

    if bucket == undefined then
    (
        bucket = #()
        spatialBuckets[bucketIndex] = bucket
    )

    append bucket #(groupIndex, positionIndex)
    true
)


fn forestAlignObjectToNormal newObj hitNormal tiltStrength =
(
    local n = normalize hitNormal
    local worldZ = [0.0, 0.0, 1.0]
    local d = dot worldZ n

    if d > 1.0 do
    (
        d = 1.0
    )
    if d < -1.0 do
    (
        d = -1.0
    )

    local rotAxis = cross worldZ n
    local rotAxisLength = length rotAxis
    local angle = acos d

    if rotAxisLength > 0.000001 then
    (
        rotAxis = normalize rotAxis
        in coordsys world
        (
            rotate newObj (angleAxis angle rotAxis)
        )
    )
    else
    (
        if d < 0.0 do
        (
            in coordsys world
            (
                rotate newObj (angleAxis 180.0 [1.0, 0.0, 0.0])
            )
        )
    )

    if tiltStrength > 0.0 do
    (
        local tangentX = cross worldZ n

        if (length tangentX) < 0.000001 then
        (
            tangentX = [1.0, 0.0, 0.0]
        )
        else
        (
            tangentX = normalize tangentX
        )

        local tangentY = cross n tangentX

        if (length tangentY) < 0.000001 then
        (
            tangentY = [0.0, 1.0, 0.0]
        )
        else
        (
            tangentY = normalize tangentY
        )

        local tiltX = random (-tiltStrength) tiltStrength
        local tiltY = random (-tiltStrength) tiltStrength

        in coordsys world
        (
            rotate newObj (angleAxis tiltX tangentX)
            rotate newObj (angleAxis tiltY tangentY)
        )
    )

    true
)


/* Draw one source using relative weights. 100 = normal, 25 = one quarter
   as frequent as another source at 100; 0 = disabled. Density unchanged. */
fn forestWeightedSourceIndex group =
(
    local total = 0.0
    for wi = 1 to group.sourceObjects.count do
    (
        local w = if wi <= group.resolvedWeights.count then group.resolvedWeights[wi] else 100.0
        total += amax 0.0 w
    )
    if total <= 0.0 then return 0
    local target = random 0.0 total
    local cumulative = 0.0
    for wi = 1 to group.sourceObjects.count do
    (
        local w = if wi <= group.resolvedWeights.count then group.resolvedWeights[wi] else 100.0
        cumulative += amax 0.0 w
        if (w > 0.0) and (target <= cumulative) do return wi
    )
    for wi = group.sourceObjects.count to 1 by -1 do
        (if group.resolvedWeights[wi] > 0.0 do return wi)
    0
)

fn generateForest =
(
    if not forestValidateInputs() then return false

    /* --------------------------------------------------------
       Шаг 1. Габариты террейна и физический масштаб сцены
       -------------------------------------------------------- */

    local terrainBBox = undefined

    in coordsys world
    (
        terrainBBox = nodeLocalBoundingBox forestTerrain
    )

    if (terrainBBox == undefined) or (terrainBBox.count < 2) then
    (
        forestStudioNotice "Не удалось получить габариты террейна." title:"Генератор леса"
        return false
    )

    local minPoint = terrainBBox[1]
    local maxPoint = terrainBBox[2]

    local minX = minPoint.x
    local maxX = maxPoint.x
    local minY = minPoint.y
    local maxY = maxPoint.y

    local terrainWidth = maxX - minX
    local terrainDepth = maxY - minY

    if (terrainWidth <= 0.0) or (terrainDepth <= 0.0) then
    (
        forestStudioNotice "Габариты террейна по XY некорректны." title:"Генератор леса"
        return false
    )

    local maskW = forestMaskBitmap.width
    local maskH = forestMaskBitmap.height
    local oneMeter = forestSceneUnitsPerMeter()

    local terrainWidthMeters = terrainWidth / oneMeter
    local terrainDepthMeters = terrainDepth / oneMeter
    local terrainAreaHa = (terrainWidthMeters * terrainDepthMeters) / 10000.0

    format "Forest Generator: 1 игровой метр = % units. Террейн по bbox: % x % м, площадь bbox % га.\n" \
        oneMeter terrainWidthMeters terrainDepthMeters terrainAreaHa

    /* Луч всегда стартует выше верхней границы террейна. */
    local rayMargin = terrainWidth
    if terrainDepth > rayMargin do rayMargin = terrainDepth
    if (100.0 * oneMeter) > rayMargin do rayMargin = 100.0 * oneMeter
    forestRayStartZ = maxPoint.z + rayMargin

    seed forestSeed

    /* --------------------------------------------------------
       Шаг 2. Подготовка групп и оценка числа ячеек

       Плотность D шт/га задаёт площадь одной потенциальной точки:
           cellArea = 10000 / D квадратных метров.

       В каждой ячейке создаётся максимум одна случайная кандидатная
       точка. Alpha пикселя является вероятностью принять кандидата.
       Поэтому математическое ожидание локальной плотности равно:
           D * Alpha.
       -------------------------------------------------------- */

    local totalGridSteps = 0.0
    local groupGridInfo = #()

    for i = 1 to forestGroupsList.count do
    (
        local group = forestGroupsList[i]
        group.sourceObjects = forestResolveGroupSourceObjects group
        group.resolvedWeights = #()
        for srcIndex = 1 to group.sourceObjects.count do
        (
            local weightVal = 100.0
            if group.usePresetSources then
            (
                local candidateRef = ""
                try (candidateRef = forestGetRefName group.sourceObjects[srcIndex]) catch()
                for refIndex = 1 to group.presetSourceRefs.count do
                (
                    if (stricmp candidateRef group.presetSourceRefs[refIndex]) == 0 do
                    (
                        if refIndex <= group.sourceWeights.count do weightVal = group.sourceWeights[refIndex]
                        exit
                    )
                )
            )
            else
            (
                if srcIndex <= group.sourceWeights.count do
                    weightVal = group.sourceWeights[srcIndex]
            )
            append group.resolvedWeights (amax 0.0 weightVal)
        )
        group.placedPositions = #()

        local cellSize = forestDensityCellSize group.densityPerHa

        if cellSize <= 0.0 then
        (
            forestStudioNotice ("Не удалось вычислить размер ячейки для группы \"" + group.groupName + "\".") title:"Генератор леса"
            return false
        )

        local cols = (ceil (terrainWidth / cellSize)) as integer
        local rows = (ceil (terrainDepth / cellSize)) as integer

        if cols < 1 do cols = 1
        if rows < 1 do rows = 1

        local cellCount = (cols as float) * (rows as float)
        totalGridSteps += cellCount

        append groupGridInfo #(cellSize, cols, rows, cellCount)
    )

    /* --------------------------------------------------------
       Шаг 3. Пространственный индекс дистанций

       Вместо сравнения каждой новой точки со всеми ранее посаженными
       объектами используется общая сетка бакетов. Размер бакета не
       меньше максимальной требуемой дистанции, поэтому для проверки
       достаточно текущего и восьми соседних бакетов.
       -------------------------------------------------------- */

    local maxRequiredDistance = 0.0

    for gi = 1 to forestGroupsList.count do
    (
        local group = forestGroupsList[gi]

        local insideDistanceScene = group.distInside * oneMeter

        if insideDistanceScene > maxRequiredDistance do
        (
            maxRequiredDistance = insideDistanceScene
        )

        for item in group.distToOther do
        (
            local otherDistanceScene = item[2] * oneMeter

            if otherDistanceScene > maxRequiredDistance do
            (
                maxRequiredDistance = otherDistanceScene
            )
        )
    )

    local spatialBucketSize = 20.0 * oneMeter
    if maxRequiredDistance > spatialBucketSize do
    (
        spatialBucketSize = maxRequiredDistance
    )
    if spatialBucketSize <= 0.0 do
    (
        spatialBucketSize = oneMeter
    )

    local bucketCols = (ceil (terrainWidth / spatialBucketSize)) as integer
    local bucketRows = (ceil (terrainDepth / spatialBucketSize)) as integer

    if bucketCols < 1 do bucketCols = 1
    if bucketRows < 1 do bucketRows = 1

    local totalBuckets = bucketCols * bucketRows
    local spatialBuckets = #()
    spatialBuckets.count = totalBuckets

    /* --------------------------------------------------------
       Шаг 4. Генерация позиций по сетке плотности
       -------------------------------------------------------- */

    progressStart "Расчёт плотности леса"

    local processedGridSteps = 0.0
    local generationOK = true

    try
    (
        for gi = 1 to forestGroupsList.count do
        (
            local group = forestGroupsList[gi]
            local gridInfo = groupGridInfo[gi]
            local cellSize = gridInfo[1]
            local cols = gridInfo[2]
            local rows = gridInfo[3]
            local placed = 0
            local matchedColorCells = 0
            local alphaAcceptedCells = 0

            local fullCellArea = cellSize * cellSize

            for rowIndex = 0 to (rows - 1) do
            (
                local cellY0 = minY + (rowIndex * cellSize)
                local cellY1 = cellY0 + cellSize
                if cellY1 > maxY do cellY1 = maxY

                local actualCellHeight = cellY1 - cellY0

                for colIndex = 0 to (cols - 1) do
                (
                    local cellX0 = minX + (colIndex * cellSize)
                    local cellX1 = cellX0 + cellSize
                    if cellX1 > maxX do cellX1 = maxX

                    local actualCellWidth = cellX1 - cellX0
                    local areaFactor = 1.0

                    if fullCellArea > 0.0 do
                    (
                        areaFactor = (actualCellWidth * actualCellHeight) / fullCellArea
                    )

                    if areaFactor < 0.0 do areaFactor = 0.0
                    if areaFactor > 1.0 do areaFactor = 1.0

                    /* Полностью случайная точка внутри физической ячейки. */
                    local x = random cellX0 cellX1
                    local y = random cellY0 cellY1

                    /* Координаты мира -> координаты пикселя маски. */
                    local u = (x - minX) / terrainWidth
                    local v = (y - minY) / terrainDepth

                    if u < 0.0 do u = 0.0
                    if v < 0.0 do v = 0.0
                    if u > 0.999999 do u = 0.999999
                    if v > 0.999999 do v = 0.999999

                    local px = floor (u * maskW)
                    /* У bitmap строка Y=0 находится сверху, а координата мира Y растёт снизу вверх.
                       Поэтому вертикальную координату маски нужно инвертировать. */
                    local py = (maskH - 1) - (floor (v * maskH))

                    if px < 0 do px = 0
                    if py < 0 do py = 0
                    if px >= maskW do px = maskW - 1
                    if py >= maskH do py = maskH - 1

                    local pixelColor = getPixelColor forestMaskBitmap px py

                    if colorMatch pixelColor group.color tolerance:10.0 do
                    (
                        matchedColorCells += 1

                        local pixelAlpha = (getPixelAlpha forestMaskBitmap px py) / 255.0
                        local acceptProbability = pixelAlpha * areaFactor

                        if acceptProbability < 0.0 do acceptProbability = 0.0
                        if acceptProbability > 1.0 do acceptProbability = 1.0

                        /* Alpha=0 должен гарантированно запрещать посадку. */
                        if (acceptProbability > 0.0) and ((random 0.0 1.0) < acceptProbability) do
                        (
                            alphaAcceptedCells += 1
                            local mayContinue = true

                            if forestUseSubObj do
                            (
                                if not (isPointInSelectedFaces forestTerrain x y) do
                                (
                                    mayContinue = false
                                )
                            )

                            if mayContinue do
                            (
                                local hit = forestRaycastAt x y

                                if hit != undefined do
                                (
                                    local hitPos = hit.pos

                                    if forestPositionAllowedSpatial gi hitPos spatialBuckets bucketCols bucketRows spatialBucketSize minX minY do
                                    (
                                        append group.placedPositions hitPos
                                        placed += 1

                                        forestSpatialAddPosition gi group.placedPositions.count hitPos spatialBuckets bucketCols bucketRows spatialBucketSize minX minY
                                    )
                                )
                            )
                        )
                    )

                    processedGridSteps += 1.0

                    /* Не обновляем UI на каждой ячейке — это заметно ускоряет большие карты. */
                    if ((mod (processedGridSteps as integer) 250) == 0) and (totalGridSteps > 0.0) do
                    (
                        local percent = ((100.0 * processedGridSteps) / totalGridSteps) as integer
                        if percent > 100 do percent = 100
                        progressUpdate percent
                    )
                )
            )

            format "Группа \"%\": плотность % шт/га, размер ячейки % м, ячеек цвета %, прошли Alpha %, размещено %.\n" \
                group.groupName \
                group.densityPerHa \
                (cellSize / oneMeter) \
                matchedColorCells \
                alphaAcceptedCells \
                placed
        )
    )
    catch
    (
        generationOK = false
    )

    if not generationOK then
    (
        progressEnd()
        forestStudioNotice "Во время расчёта позиций произошла ошибка. Генерация остановлена." title:"Генератор леса"
        return false
    )

    progressUpdate 100

    /* --------------------------------------------------------
       Шаг 5. Создание объектов
       -------------------------------------------------------- */

    local creationOK = true
    local totalCreated = 0

    suspendEditing()

    try
    (
        undo "Генерация леса" on
        (
            with redraw off
            (
                for gi = 1 to forestGroupsList.count do
                (
                    local group = forestGroupsList[gi]

                    if group.placedPositions.count > 0 do
                    (
                        local resultLayerName = "Forest_" + group.layerName
                        local resultLayer = createForestLayer resultLayerName
                        local createdNodes = #()

                        if resultLayer == undefined then
                        (
                            creationOK = false
                        )
                        else
                        (
                            for hitPos in group.placedPositions do
                            (
                                local sourceIndex = forestWeightedSourceIndex group
                                local sourceNode = if sourceIndex > 0 then group.sourceObjects[sourceIndex] else undefined
                                local newObj = if sourceNode != undefined then (instance sourceNode) else undefined

                                if newObj != undefined do
                                (
                                    /* Явно переносим метаданные исходного SDK/LOD-объекта.
                                       Для X-Ray особенно важен User Property ref_name. */
                                    try
                                    (
                                        setUserPropBuffer newObj (getUserPropBuffer sourceNode)
                                    )
                                    catch()

                                    try (setUserProp newObj "forest_generated" true) catch()

                                    newObj.pos = hitPos

                                    local s = random group.scaleMin group.scaleMax
                                    newObj.scale = [s, s, s]

                                    if group.randomRotY do
                                    (
                                        in coordsys world
                                        (
                                            rotate newObj (angleAxis (random 0.0 360.0) [0.0, 0.0, 1.0])
                                        )
                                    )

                                    if group.alignNormal do
                                    (
                                        local normalHit = forestRaycastAt hitPos.x hitPos.y

                                        if normalHit != undefined do
                                        (
                                            forestAlignObjectToNormal newObj normalHit.dir group.tiltStrength
                                        )
                                    )

                                    append createdNodes newObj
                                    totalCreated += 1
                                )
                            )

                            if createdNodes.count > 0 do
                            (
                                try
                                (
                                    resultLayer.addnodes createdNodes
                                )
                                catch
                                (
                                    for n in createdNodes do
                                    (
                                        try
                                        (
                                            resultLayer.addNode n
                                        )
                                        catch()
                                    )
                                )
                            )
                        )
                    )
                )
            )
        )
    )
    catch
    (
        creationOK = false
    )

    resumeEditing()
    progressEnd()

    if not creationOK then
    (
        forestStudioNotice "При создании объектов произошла ошибка. Часть объектов могла быть создана; используйте Ctrl+Z для отмены блока \"Генерация леса\"." title:"Генератор леса"
        return false
    )

    forestStudioNotice ("Готово! Создано объектов: " + (totalCreated as string)) title:"Генератор леса"
    true
)


/* ------------------------------------------------------------
   STALKER SDK: ИМПОРТ .OBJECT, СОЗДАНИЕ LOD, ЭКСПОРТ .PART
   ------------------------------------------------------------ */

fn forestTrimTrailingSlash pathText =
(
    local result = pathText

    if result == undefined do result = ""

    while (result.count > 0) and ((result[result.count] == "\\") or (result[result.count] == "/")) do
    (
        result = substring result 1 (result.count - 1)
    )

    result
)


fn forestSettingsFile =
(
    scriptspath + "xr_scripts_settings.txt"
)


fn forestLoadSDKSettings =
(
    local settingsName = forestSettingsFile()

    if forestSDKObjectsRoot == "" do
    (
        try
        (
            forestSDKObjectsRoot = forestTrimTrailingSlash (getIniSetting settingsName "paths" "last_objects_path")
        )
        catch()
    )

    if forestSDKTexturesRoot == "" do
    (
        try
        (
            forestSDKTexturesRoot = forestTrimTrailingSlash (getIniSetting settingsName "paths" "last_textures_path")
        )
        catch()
    )

    if forestObjectImporterScript == "" do
    (
        try
        (
            forestObjectImporterScript = getIniSetting settingsName "forest_generator" "object_importer"
        )
        catch()
    )

    if forestLastScenePart == "" do
    (
        try
        (
            forestLastScenePart = getIniSetting settingsName "forest_generator" "scene_object_part"
        )
        catch()
    )

    if forestLodTextureDir == "" do
    (
        try
        (
            forestLodTextureDir = forestTrimTrailingSlash (getIniSetting settingsName "forest_generator" "lod_texture_path")
        )
        catch()
    )

    if forestLodTextureDir == "" do
    (
        local userScriptsDir = ""
        try (userScriptsDir = getDir #userScripts) catch()

        if userScriptsDir != "" then
        (
            forestLodTextureDir = forestTrimTrailingSlash userScriptsDir + "\\ForestGenerator_LOD"
            try (makeDir forestLodTextureDir all:true) catch()
        )
    )

    true
)


fn forestSaveSDKObjectsRoot rootPath =
(
    forestSDKObjectsRoot = forestTrimTrailingSlash rootPath

    if forestSDKObjectsRoot != "" do
    (
        try
        (
            setIniSetting (forestSettingsFile()) "paths" "last_objects_path" forestSDKObjectsRoot forceUTF16:false
        )
        catch()
    )

    forestSDKObjectsRoot
)


fn forestSaveSDKTexturesRoot rootPath =
(
    forestSDKTexturesRoot = forestTrimTrailingSlash rootPath

    if forestSDKTexturesRoot != "" do
    (
        try
        (
            setIniSetting (forestSettingsFile()) "paths" "last_textures_path" forestSDKTexturesRoot forceUTF16:false
        )
        catch()
    )

    forestSDKTexturesRoot
)


fn forestSaveImporterScript scriptName =
(
    forestObjectImporterScript = scriptName

    if forestObjectImporterScript != "" do
    (
        try
        (
            setIniSetting (forestSettingsFile()) "forest_generator" "object_importer" forestObjectImporterScript forceUTF16:false
        )
        catch()
    )

    forestObjectImporterScript
)


fn forestSaveLodTextureDir dirName =
(
    forestLodTextureDir = forestTrimTrailingSlash dirName

    if forestLodTextureDir != "" do
    (
        try
        (
            setIniSetting (forestSettingsFile()) "forest_generator" "lod_texture_path" forestLodTextureDir forceUTF16:false
        )
        catch()
    )

    forestLodTextureDir
)


fn forestSaveScenePart partName =
(
    forestLastScenePart = partName

    if forestLastScenePart != "" do
    (
        try
        (
            setIniSetting (forestSettingsFile()) "forest_generator" "scene_object_part" forestLastScenePart forceUTF16:false
        )
        catch()
    )

    forestLastScenePart
)


fn forestFindObjectImporterScript =
(
    if (forestObjectImporterScript != "") and (doesFileExist forestObjectImporterScript) do
    (
        return forestObjectImporterScript
    )

    local sourceName = undefined
    local sourceDir = ""

    try (sourceName = getSourceFileName()) catch()
    if sourceName != undefined do
    (
        try (sourceDir = getFilenamePath sourceName) catch()
    )

    local candidates = #(
        sourceDir + "xrTools.ObjectImport.ms",
        sourceDir + "xray_tools\\xrTools.ObjectImport.ms",
        scriptspath + "xrTools.ObjectImport.ms",
        scriptspath + "xray_tools\\xrTools.ObjectImport.ms",
        scriptspath + "XR_Tools\\xrTools.ObjectImport.ms"
    )

    for candidateName in candidates do
    (
        if (candidateName != "") and (doesFileExist candidateName) do
        (
            forestSaveImporterScript candidateName
            return forestObjectImporterScript
        )
    )

    ""
)


fn forestEnsureObjectImporterLoaded allowBrowse:true =
(
    /* Если rollout уже определён, не fileIn-им импортёр повторно. */
    local alreadyLoaded = false

    try
    (
        if XRay_ImportModel_rol != undefined do
        (
            local loaderFunction = XRay_ImportModel_rol.load_object
            local finalFunction = XRay_ImportModel_rol.FinalSettings
            alreadyLoaded = (loaderFunction != undefined) and (finalFunction != undefined)
        )
    )
    catch
    (
        alreadyLoaded = false
    )

    if alreadyLoaded then
    (
        try
        (
            XRay_ImportModel_rol.AttachChk.checked = true
            XRay_ImportModel_rol.MergeMaterials.checked = true
            XRay_ImportModel_rol.LoadBatchChk.checked = false
            XRay_ImportModel_rol.LoadSkinChk.checked = false
            XRay_ImportModel_rol.LoadShapeChk.checked = false
            XRay_ImportModel_rol.PutToLayers.checked = false
            XRay_ImportModel_rol.LoadMaps.checked = true
            XRay_ImportModel_rol.ScaleObject.value = 1.0
            XRay_ImportModel_rol.xrMtlType.selection = 3
            XRay_ImportModel_rol.SGImportType.selection = 1
            if forestSDKObjectsRoot != "" do XRay_ImportModel_rol.ObjPathTxt.text = forestSDKObjectsRoot
            if forestSDKTexturesRoot != "" do XRay_ImportModel_rol.TPathTxt.text = forestSDKTexturesRoot
        )
        catch()

        return true
    )

    local importerName = forestFindObjectImporterScript()

    if (importerName == "") and allowBrowse do
    (
        importerName = getOpenFileName \
            caption:"Укажите xrTools.ObjectImport.ms" \
            types:"MAXScript (*.ms)|*.ms|"

        if importerName != undefined do
        (
            forestSaveImporterScript importerName
        )
    )

    if (importerName == undefined) or (importerName == "") do return false
    if not doesFileExist importerName do return false

    local loadedOK = true

    try
    (
        fileIn importerName
    )
    catch
    (
        loadedOK = false
    )

    if not loadedOK do return false

    /* Сам импортёр создаёт собственный floater. Он нам не нужен: используем
       его проверенные функции load_object / FinalSettings как backend. */
    try (closeRolloutFloater XRay_ImportModel_flo) catch()

    local apiOK = true

    try
    (
        XRay_ImportModel_rol.AttachChk.checked = true
        XRay_ImportModel_rol.MergeMaterials.checked = true
        XRay_ImportModel_rol.LoadBatchChk.checked = false
        XRay_ImportModel_rol.LoadSkinChk.checked = false
        XRay_ImportModel_rol.LoadShapeChk.checked = false
        XRay_ImportModel_rol.PutToLayers.checked = false
        XRay_ImportModel_rol.LoadMaps.checked = true
        XRay_ImportModel_rol.ScaleObject.value = 1.0
        XRay_ImportModel_rol.xrMtlType.selection = 3
        XRay_ImportModel_rol.SGImportType.selection = 1

        if forestSDKObjectsRoot != "" do
        (
            XRay_ImportModel_rol.ObjPathTxt.text = forestSDKObjectsRoot
        )

        if forestSDKTexturesRoot != "" do
        (
            XRay_ImportModel_rol.TPathTxt.text = forestSDKTexturesRoot
        )
    )
    catch
    (
        apiOK = false
    )

    apiOK
)


fn forestNormalizeRefName refText =
(
    if refText == undefined then
    (
        ""
    )
    else
    (
        substituteString (refText as string) "/" "\\"
    )
)


fn forestObjectFileIsUnderSDKRoot objectFileName =
(
    local rootPath = forestTrimTrailingSlash forestSDKObjectsRoot

    if rootPath == "" do return false

    local rootWithSlash = toLower (rootPath + "\\")
    local fullName = toLower objectFileName

    (fullName.count >= rootWithSlash.count) and ((substring fullName 1 rootWithSlash.count) == rootWithSlash)
)


fn forestRefNameFromObjectPath objectFileName =
(
    local rootPath = forestTrimTrailingSlash forestSDKObjectsRoot
    local fullWithoutExt = (getFilenamePath objectFileName) + (getFilenameFile objectFileName)

    if rootPath == "" then return (getFilenameFile objectFileName)

    local rootWithSlash = rootPath + "\\"
    local lowerFull = toLower fullWithoutExt
    local lowerRoot = toLower rootWithSlash

    if (lowerFull.count >= lowerRoot.count) and ((substring lowerFull 1 lowerRoot.count) == lowerRoot) then
    (
        substring fullWithoutExt (rootWithSlash.count + 1) -1
    )
    else
    (
        getFilenameFile objectFileName
    )
)


fn forestGetRefName obj =
(
    if (obj == undefined) or (not isValidNode obj) do return ""

    local refName = undefined

    try (refName = getUserProp obj "ref_name") catch()

    if (refName == undefined) or ((refName as string) == "") do
    (
        try (refName = getUserProp obj "RefObj") catch()
    )

    if refName == undefined then
        ""
    else
        forestNormalizeRefName refName
)


fn forestImportOneObject objectFileName =
(
    if not doesFileExist objectFileName do return undefined
    if forestSDKObjectsRoot == "" do return undefined

    if not forestObjectFileIsUnderSDKRoot objectFileName then
    (
        format "Import skipped: file is outside SDK objects root: %\n" objectFileName
        return undefined
    )

    local importedNode = undefined
    local importStream = undefined

    try
    (
        XRay_ImportModel_rol.AttachChk.checked = true
        XRay_ImportModel_rol.MergeMaterials.checked = true
        XRay_ImportModel_rol.LoadBatchChk.checked = false
        XRay_ImportModel_rol.LoadSkinChk.checked = false
        XRay_ImportModel_rol.LoadShapeChk.checked = false
        XRay_ImportModel_rol.PutToLayers.checked = false
        XRay_ImportModel_rol.LoadMaps.checked = true
        XRay_ImportModel_rol.ScaleObject.value = 1.0
        XRay_ImportModel_rol.xrMtlType.selection = 3
        XRay_ImportModel_rol.SGImportType.selection = 1
        XRay_ImportModel_rol.ObjPathTxt.text = forestSDKObjectsRoot
        if forestSDKTexturesRoot != "" do XRay_ImportModel_rol.TPathTxt.text = forestSDKTexturesRoot

        importStream = fopen objectFileName "rb"

        if importStream != undefined do
        (
            local objectFileSize = getFileSize objectFileName
            local importData = undefined

            with redraw off
            (
                importData = XRay_ImportModel_rol.load_object importStream objectFileName objectFileSize true false
            )

            importedNode = XRay_ImportModel_rol.FinalSettings importData objectFileName
        )
    )
    catch
    (
        importedNode = undefined
    )

    if importStream != undefined do
    (
        try (fclose importStream) catch()
    )

    if importedNode != undefined do
    (
        local expectedRefName = forestNormalizeRefName (forestRefNameFromObjectPath objectFileName)
        local refName = forestGetRefName importedNode

        /* Корень sdk\rawdata\objects — авторитетный. Если старый importer
           сохранил иной ref_name из-за своих настроек, исправляем его. */
        if (refName == "") or ((stricmp refName expectedRefName) != 0) do
        (
            refName = expectedRefName
            try (setUserProp importedNode "ref_name" refName) catch()
        )

        try (setUserProp importedNode "forest_sdk_source" true) catch()
    )

    importedNode
)


fn forestImportObjectFiles fileNames =
(
    forestLoadSDKSettings()

    if forestSDKObjectsRoot == "" then
    (
        forestStudioNotice "Сначала укажите sdk\\rawdata\\objects." title:"Forest Generator — Import"
        return #()
    )

    if not doesDirectoryExist forestSDKObjectsRoot then
    (
        forestStudioNotice "Папка sdk\\rawdata\\objects не существует." title:"Forest Generator — Import"
        return #()
    )

    if (forestSDKTexturesRoot == "") or (not doesDirectoryExist forestSDKTexturesRoot) then
    (
        forestStudioNotice "Не найдена папка sdk\\gamedata\\textures. Она нужна для импорта материалов и создания LOD." title:"Forest Generator — Import"
        return #()
    )

    if fileNames.count == 0 do return #()

    if not (forestEnsureObjectImporterLoaded allowBrowse:true) then
    (
        forestStudioNotice "Не удалось загрузить xrTools.ObjectImport.ms. Укажите рабочий импортёр X-Ray Object." title:"Forest Generator — Import"
        return #()
    )

    local importedNodes = #()
    local failedFiles = #()
    local sourceLayer = createForestLayer "FG_Imported_Originals"

    progressStart "Импорт X-Ray .object"

    for fileIndex = 1 to fileNames.count do
    (
        local objectFileName = fileNames[fileIndex]
        local importedNode = forestImportOneObject objectFileName

        if importedNode != undefined then
        (
            append importedNodes importedNode

            if sourceLayer != undefined do
            (
                try (sourceLayer.addNode importedNode) catch()
            )
        )
        else
        (
            append failedFiles objectFileName
        )

        progressUpdate ((100.0 * fileIndex) / fileNames.count)
    )

    progressEnd()

    if importedNodes.count > 0 do
    (
        select importedNodes
        forestRefreshLayerDropdown()
    )

    format "Forest Generator Import: imported %, failed %.\n" importedNodes.count failedFiles.count

    if failedFiles.count > 0 do
    (
        format "Failed files:\n"
        for failedName in failedFiles do format "  %\n" failedName
    )

    importedNodes
)


fn forestSanitizeFileName sourceText =
(
    local result = ""
    local forbiddenChars = "\\/:*?\"<>|"

    for charIndex = 1 to sourceText.count do
    (
        local oneChar = sourceText[charIndex]

        if (findString forbiddenChars oneChar) == undefined do
        (
            result += oneChar
        )
    )

    if result == "" then "forest_lod" else result
)


fn forestCreateLODPlane sourceNode angleDegrees =
(
    local sourceSize = sourceNode.max - sourceNode.min
    local sourceCenter = [sourceNode.pos.x, sourceNode.pos.y, sourceNode.center.z]
    local planeTM = (rotateZMatrix angleDegrees) * (transMatrix sourceCenter)
    local inverseTM = inverse planeTM
    local projectedX = #()

    append projectedX (([sourceNode.min.x, sourceNode.min.y, sourceCenter.z] * inverseTM).x)
    append projectedX (([sourceNode.min.x, sourceNode.max.y, sourceCenter.z] * inverseTM).x)
    append projectedX (([sourceNode.max.x, sourceNode.min.y, sourceCenter.z] * inverseTM).x)
    append projectedX (([sourceNode.max.x, sourceNode.max.y, sourceCenter.z] * inverseTM).x)

    local planeWidth = (amax projectedX) - (amin projectedX)
    local planeHeight = sourceSize.z

    if planeWidth <= 0.0 do planeWidth = 0.01
    if planeHeight <= 0.0 do planeHeight = 0.01

    local lodPlane = plane \
        length:planeHeight \
        width:planeWidth \
        lengthSegs:1 \
        widthSegs:1 \
        mapCoords:true

    lodPlane.rotation.x_rotation = 90
    lodPlane.transform *= planeTM

    lodPlane
)


fn forestRenderLODFromPlane lodPlane renderSize outputName =
(
    local cameraDistance = (amax lodPlane.width lodPlane.length) / 2.0

    if cameraDistance <= 0.0 do cameraDistance = 1.0

    local cameraTM = (transMatrix [0.0, 0.0, cameraDistance]) * lodPlane.transform
    local lodCamera = freeCamera fov:90 orthoProjection:true targetDistance:cameraDistance
    local renderOK = true

    lodCamera.transform = cameraTM

    try
    (
        local renderedBitmap = render \
            camera:lodCamera \
            outputSize:[renderSize, renderSize] \
            outputFile:outputName \
            quiet:true \
            vfb:false

        if renderedBitmap != undefined do
        (
            try (close renderedBitmap) catch()
        )
    )
    catch
    (
        renderOK = false
    )

    try (delete lodCamera) catch()

    renderOK
)


fn forestMakeLODForObject sourceNode planeCount renderSize textureDirectory useExistingTexture:false =
(
    if (sourceNode == undefined) or (not isValidNode sourceNode) do return undefined
    if planeCount < 1 do return undefined

    local refName = forestGetRefName sourceNode

    if refName == "" then
    (
        format "LOD skipped: % has no ref_name.\n" sourceNode.name
        return undefined
    )

    local combinedLOD = undefined
    local angleStep = 180.0 / planeCount
    local safeName = forestSanitizeFileName sourceNode.name
    local outputDir = forestTrimTrailingSlash textureDirectory

    for planeIndex = 0 to (planeCount - 1) do
    (
        local lodPlane = undefined
        local planeOK = true

        try
        (
            lodPlane = forestCreateLODPlane sourceNode (planeIndex * angleStep)

            if lodPlane != undefined do
            (
                lodPlane.renderable = false

                local textureName = outputDir + "\\" + safeName + "_lod" + (planeIndex as string) + ".tga"
                local textureReady = false

                if useExistingTexture and (doesFileExist textureName) then
                (
                    textureReady = true
                )
                else
                (
                    textureReady = forestRenderLODFromPlane lodPlane renderSize textureName
                )

                if textureReady then
                (
                    local lodMaterial = standard twoSided:true
                    lodMaterial.diffuseMap = bitmapTexture filename:textureName monoOutput:0 RGBOutput:0 alphaSource:2
                    lodMaterial.opacityMap = bitmapTexture filename:textureName monoOutput:1 RGBOutput:1 alphaSource:0
                    showTextureMap lodMaterial true
                    lodPlane.material = lodMaterial

                    local uvSize = amax lodPlane.width lodPlane.length
                    if uvSize <= 0.0 do uvSize = 0.01

                    local uvwModifier = uvwMap length:uvSize width:uvSize
                    addModifier lodPlane uvwModifier
                    convertToMesh lodPlane

                    if combinedLOD == undefined then
                        combinedLOD = lodPlane
                    else
                        attach combinedLOD lodPlane
                )
                else
                (
                    try (delete lodPlane) catch()
                    lodPlane = undefined
                )
            )
        )
        catch
        (
            planeOK = false
            format "LOD plane ERROR: % plane % | %\n" sourceNode.name planeIndex (getCurrentException())
        )

        if not planeOK do
        (
            if (lodPlane != undefined) and (isValidNode lodPlane) do
            (
                if (combinedLOD == undefined) or (lodPlane != combinedLOD) do
                (
                    try (delete lodPlane) catch()
                )
            )
        )
    )

    if combinedLOD != undefined do
    (
        try (setUserPropBuffer combinedLOD (getUserPropBuffer sourceNode)) catch()
        try (setUserProp combinedLOD "ref_name" refName) catch()
        try (setUserProp combinedLOD "forest_lod_source" true) catch()

        combinedLOD.name = "LOD_" + sourceNode.name

        try (combinedLOD.pivot = sourceNode.pivot) catch()
        try (resetXForm combinedLOD) catch()
        try (convertToMesh combinedLOD) catch()

        /* Повторяем критичные User Properties после конвертации. */
        try (setUserProp combinedLOD "ref_name" refName) catch()
        try (setUserProp combinedLOD "forest_lod_source" true) catch()
    )

    combinedLOD
)


fn forestMakeLODsFromSelection planeCount:3 renderSize:128 textureDirectory:"" useExistingTexture:false deleteOriginals:true =
(
    local outputDir = forestTrimTrailingSlash textureDirectory

    if outputDir == "" then
    (
        forestStudioNotice "Укажите папку для LOD-текстур." title:"Forest Generator — LOD"
        return #()
    )

    if not doesDirectoryExist outputDir then
    (
        forestStudioNotice "Папка LOD-текстур не существует." title:"Forest Generator — LOD"
        return #()
    )

    local sourceNodes = for selectedNode in selection where \
        (isValidNode selectedNode) and (superClassOf selectedNode == GeometryClass) collect selectedNode

    if sourceNodes.count == 0 then
    (
        forestStudioNotice "Выделите импортированные исходные деревья." title:"Forest Generator — LOD"
        return #()
    )

    local geometryStates = #()

    for sceneNode in $geometry do
    (
        append geometryStates #(sceneNode, sceneNode.renderable)
        sceneNode.renderable = false
    )

    local lodNodes = #()
    local originalsToDelete = #()
    local lodLayer = createForestLayer "FG_LOD_Sources"

    progressStart "Создание Forest LOD"

    for sourceIndex = 1 to sourceNodes.count do
    (
        local sourceNode = sourceNodes[sourceIndex]

        if isValidNode sourceNode do
        (
            sourceNode.renderable = true

            local newLOD = undefined

            try
            (
                newLOD = forestMakeLODForObject \
                    sourceNode \
                    planeCount \
                    renderSize \
                    outputDir \
                    useExistingTexture:useExistingTexture
            )
            catch
            (
                format "LOD ERROR: % | %\n" sourceNode.name (getCurrentException())
                newLOD = undefined
            )

            sourceNode.renderable = false

            if newLOD != undefined then
            (
                append lodNodes newLOD
                append originalsToDelete sourceNode

                if lodLayer != undefined do
                (
                    try (lodLayer.addNode newLOD) catch()
                )
            )
        )

        progressUpdate ((100.0 * sourceIndex) / sourceNodes.count)
    )

    for statePair in geometryStates do
    (
        local stateNode = statePair[1]
        if isValidNode stateNode do stateNode.renderable = statePair[2]
    )

    /* Новые LOD не входили в geometryStates. Во время рендера они были
       renderable=false, теперь возвращаем нормальное состояние. */
    for lodNode in lodNodes do
    (
        if isValidNode lodNode do lodNode.renderable = true
    )

    if deleteOriginals do
    (
        for originalNode in originalsToDelete do
        (
            if isValidNode originalNode do delete originalNode
        )
    )

    progressEnd()

    if lodNodes.count > 0 do
    (
        select lodNodes
        forestRefreshLayerDropdown()
    )

    format "Forest Generator LOD: created % LOD object(s).\n" lodNodes.count
    lodNodes
)


fn forestCollectGeneratedNodes =
(
    local result = #()

    if LayerManager.count > 0 do
    (
        for layerIndex = 0 to (LayerManager.count - 1) do
        (
            local sceneLayer = LayerManager.getLayer layerIndex

            if sceneLayer != undefined do
            (
                if matchPattern sceneLayer.name pattern:"Forest_*" ignoreCase:true do
                (
                    local layerNodes = #()

                    try
                    (
                        if (sceneLayer.nodes &layerNodes) do
                        (
                            for forestNode in layerNodes do
                            (
                                if (isValidNode forestNode) and \
                                   (superClassOf forestNode == GeometryClass) and \
                                   (forestNode.parent == undefined) do
                                (
                                    append result forestNode
                                )
                            )
                        )
                    )
                    catch()
                )
            )
        )
    )

    result
)


fn forestPadInteger numberValue digitCount =
(
    local result = numberValue as string

    while result.count < digitCount do
    (
        result = "0" + result
    )

    result
)


fn forestFloatString numberValue =
(
    local result = formattedPrint numberValue format:".9g"
    substituteString result "," "."
)


fn forestPoint3CSV xValue yValue zValue =
(
    (forestFloatString xValue) + ", " + \
    (forestFloatString yValue) + ", " + \
    (forestFloatString zValue)
)


fn forestBuildExportBaseName refName prefixText =
(
    local normalizedRef = forestNormalizeRefName refName
    local refParts = filterString normalizedRef "\\"
    local baseRef = normalizedRef
    -- Add a single underscore between the user prefix and the asset name.
    local safePrefix = prefixText
    if safePrefix != "" do
    (
        if (substring safePrefix safePrefix.count 1) != "_" do safePrefix += "_"
    )

    if safePrefix != "" do
    (
        if refParts.count > 1 then
        (
            local rebuilt = ""

            for partIndex = 1 to (refParts.count - 1) do
            (
                rebuilt += refParts[partIndex] + "\\"
            )

            rebuilt += safePrefix + refParts[refParts.count]
            baseRef = rebuilt
        )
        else
        (
            baseRef = safePrefix + normalizedRef
        )
    )

    baseRef
)


fn forestTrailingNumericSuffix objectName baseName =
(
    local prefixText = baseName + "_"

    if objectName.count <= prefixText.count do return undefined
    if (stricmp (substring objectName 1 prefixText.count) prefixText) != 0 do return undefined

    local suffixText = substring objectName (prefixText.count + 1) -1

    if suffixText == "" do return undefined

    for charIndex = 1 to suffixText.count do
    (
        if (findString "0123456789" suffixText[charIndex]) == undefined do return undefined
    )

    local suffixValue = undefined
    try (suffixValue = suffixText as integer) catch()
    suffixValue
)


fn forestFindNameCounterIndex baseNames baseName =
(
    for baseIndex = 1 to baseNames.count do
    (
        if (stricmp baseNames[baseIndex] baseName) == 0 do return baseIndex
    )

    0
)


fn forestBuildExportNameFast refName prefixText baseNames nextSuffixes =
(
    local baseName = forestBuildExportBaseName refName prefixText
    local counterIndex = forestFindNameCounterIndex baseNames baseName

    if counterIndex == 0 then
    (
        append baseNames baseName
        append nextSuffixes 1
        baseName + "_" + (forestPadInteger 0 5)
    )
    else
    (
        local suffixValue = nextSuffixes[counterIndex]
        nextSuffixes[counterIndex] = suffixValue + 1
        baseName + "_" + (forestPadInteger suffixValue 5)
    )
)


fn forestReadPartObjectCount partFileName =
(
    local countText = ""

    try (countText = getINISetting partFileName "main" "objects_count") catch()

    if countText == "" then return undefined

    local countValue = undefined
    try (countValue = execute countText) catch()

    if countValue == undefined then undefined else (countValue as integer)
)


fn forestValidateExportNodes exportNodes =
(
    local validNodes = #()
    local issues = #()
    local rootPath = forestTrimTrailingSlash forestSDKObjectsRoot

    if rootPath == "" then
    (
        append issues "Не задан путь sdk\\rawdata\\objects."
        return #(validNodes, issues)
    )

    for exportNode in exportNodes do
    (
        if (exportNode == undefined) or (not isValidNode exportNode) then
        (
            append issues "Невалидный объект в наборе экспорта."
        )
        else
        (
            local refName = forestGetRefName exportNode

            if refName == "" then
            (
                append issues ("Нет ref_name: " + exportNode.name)
            )
            else
            (
                local sdkObjectName = rootPath + "\\" + refName + ".object"

                if not doesFileExist sdkObjectName then
                (
                    append issues ("Не найден .object: " + sdkObjectName)
                )
                else
                (
                    append validNodes exportNode
                )
            )
        )
    )

    #(validNodes, issues)
)


fn forestPrintIssues issues maxLines:30 =
(
    local lineCount = amin issues.count maxLines

    for issueIndex = 1 to lineCount do
    (
        format "  %\n" issues[issueIndex]
    )

    if issues.count > maxLines do
    (
        format "  ... and % more issue(s).\n" (issues.count - maxLines)
    )
)


fn forestExportNodesToPart exportNodes partFileName prefixText:"" =
(
    if not doesFileExist partFileName then
    (
        forestStudioNotice "scene_object.part не найден." title:"Forest Generator — Export"
        return false
    )

    local oldObjectCount = forestReadPartObjectCount partFileName

    if oldObjectCount == undefined then
    (
        forestStudioNotice "Не удалось прочитать [main] objects_count из scene_object.part." title:"Forest Generator — Export"
        return false
    )

    local validation = forestValidateExportNodes exportNodes
    local validNodes = validation[1]
    local issues = validation[2]

    if issues.count > 0 then
    (
        format "Forest Export validation failed (% issues):\n" issues.count
        forestPrintIssues issues
        forestStudioNotice ("Экспорт остановлен. Ошибок проверки: " + (issues.count as string) + ".\nПодробности — в Listener.") title:"Forest Generator — Export"
        return false
    )

    if validNodes.count == 0 then
    (
        forestStudioNotice "Нет объектов для экспорта." title:"Forest Generator — Export"
        return false
    )

    /* Счётчики имён строим один раз по существующему .part.
       Это повторяет идею старого exporter, но не делает O(N^2) сравнений
       при экспорте десятков тысяч деревьев. */
    local nameBases = #()
    local nextSuffixes = #()

    if oldObjectCount > 0 do
    (
        for existingIndex = 0 to (oldObjectCount - 1) do
        (
            local sectionName = "object_" + (existingIndex as string)
            local existingName = ""
            local existingRef = ""

            try (existingName = getINISetting partFileName sectionName "name") catch()
            try (existingRef = getINISetting partFileName sectionName "reference_name") catch()

            if (existingName != "") and (existingRef != "") do
            (
                local baseName = forestBuildExportBaseName existingRef prefixText
                local suffixValue = forestTrailingNumericSuffix existingName baseName

                if suffixValue != undefined do
                (
                    local counterIndex = forestFindNameCounterIndex nameBases baseName

                    if counterIndex == 0 then
                    (
                        append nameBases baseName
                        append nextSuffixes (suffixValue + 1)
                    )
                    else
                    (
                        if nextSuffixes[counterIndex] <= suffixValue do
                        (
                            nextSuffixes[counterIndex] = suffixValue + 1
                        )
                    )
                )
            )
        )
    )

    local backupName = partFileName + ".forest_backup_" + ((timestamp()) as string)

    if not copyFile partFileName backupName then
    (
        forestStudioNotice "Не удалось создать резервную копию scene_object.part. Экспорт отменён." title:"Forest Generator — Export"
        return false
    )

    local exportOK = true
    local currentCount = oldObjectCount
    local unitsPerMeter = forestSceneUnitsPerMeter()
    local partStream = undefined

    if unitsPerMeter <= 0.0 do unitsPerMeter = 1.0

    progressStart "Экспорт Forest в scene_object.part"

    try
    (
        /* Для большого леса не вызываем setINISetting по 9 раз на каждый объект.
           Открываем .part один раз и дописываем секции последовательно.
           #current + writeBOM:false не добавляют новый Unicode BOM в X-Ray part. */
        partStream = openFile partFileName mode:"a" encoding:#current writeBOM:false

        if partStream == undefined then
        (
            exportOK = false
        )
        else
        (
            for exportIndex = 1 to validNodes.count while exportOK do
            (
                local exportNode = validNodes[exportIndex]
                local refName = forestGetRefName exportNode
                local objectName = forestBuildExportNameFast refName prefixText nameBases nextSuffixes

                local exportPosition = exportNode.position / unitsPerMeter
                local exportEuler = quatToEuler exportNode.transform.rotation order:4
                local rotationX = degToRad exportEuler.x
                local rotationY = degToRad exportEuler.y
                local rotationZ = degToRad exportEuler.z
                local exportScale = exportNode.scale

                /* Формат секции повторяет старый рабочий STALKER exporter. */
                format "\r\n[object_%]\r\n" currentCount to:partStream
                format "\tclsid\t\t\t\t= 2\r\n" to:partStream
                format "\tco_flags\t\t\t= 0\r\n" to:partStream
                format "\tflags\t\t\t\t= 0\r\n" to:partStream
                format "\tname\t\t\t\t= %\r\n" objectName to:partStream
                format "\tposition\t\t\t= %\r\n" (forestPoint3CSV exportPosition.x exportPosition.z exportPosition.y) to:partStream
                format "\treference_name\t\t\t= %\r\n" refName to:partStream
                format "\trotation\t\t\t= %\r\n" (forestPoint3CSV rotationY rotationZ rotationX) to:partStream
                format "\tscale\t\t\t\t= %\r\n" (forestPoint3CSV exportScale.x exportScale.z exportScale.y) to:partStream
                format "\tversion\t\t\t\t= 18\r\n" to:partStream

                currentCount += 1

                if ((mod exportIndex 250) == 0) or (exportIndex == validNodes.count) do
                (
                    progressUpdate ((100.0 * exportIndex) / validNodes.count)
                )
            )

            flush partStream
            close partStream
            partStream = undefined
        )

        /* [main] меняем только после успешной записи всех object-секций.
           forceUTF16:false обязателен: X-Ray .part должен остаться ANSI/ASCII-совместимым. */
        if exportOK do
        (
            exportOK = setINISetting partFileName "main" "objects_count" (currentCount as string) forceUTF16:false
        )

        /* После записи сразу перечитываем ключевые данные через INI parser.
           Если X-Ray-подобная структура сломалась, откатываемся к backup. */
        if exportOK do
        (
            local verifyCount = forestReadPartObjectCount partFileName
            if verifyCount != currentCount do exportOK = false

            if exportOK and (validNodes.count > 0) do
            (
                local lastSection = "object_" + ((currentCount - 1) as string)
                local writtenRef = ""
                local expectedRef = forestGetRefName validNodes[validNodes.count]

                try (writtenRef = getINISetting partFileName lastSection "reference_name") catch()

                if (stricmp (forestNormalizeRefName writtenRef) expectedRef) != 0 do
                (
                    exportOK = false
                )
            )
        )
    )
    catch
    (
        exportOK = false
        format "Forest Export exception: %\n" (getCurrentException())
    )

    if partStream != undefined do
    (
        try (close partStream) catch()
        partStream = undefined
    )

    progressEnd()

    if not exportOK then
    (
        format "Forest Export ERROR. Restoring backup: %\n" backupName

        local restoreOK = false

        try
        (
            if doesFileExist partFileName do deleteFile partFileName
            restoreOK = copyFile backupName partFileName
        )
        catch
        (
            restoreOK = false
        )

        if restoreOK then
            forestStudioNotice "Ошибка записи .part. Исходный файл восстановлен из backup. Смотрите Listener." title:"Forest Generator — Export"
        else
            forestStudioNotice ("Ошибка записи .part И не удалось автоматически восстановить файл.\nBackup сохранён здесь:\n" + backupName) title:"Forest Generator — Export"

        return false
    )

    format "Forest Export: % object(s) appended. objects_count: % -> %.\n" validNodes.count oldObjectCount currentCount
    format "Backup: %\n" backupName

    forestStudioNotice ("Экспорт завершён. Добавлено объектов: " + (validNodes.count as string) + ".\nBackup: " + backupName) title:"Forest Generator — Export"
    true
)


/* ------------------------------------------------------------
   ВСПОМОГАТЕЛЬНЫЕ ОКНА STALKER SDK
   ------------------------------------------------------------ */


rollout forestPresetUI "Пресеты и память генератора"
(
    groupBox gbNamed "Именованные пресеты" pos:[10,10] width:500 height:205

    dropdownlist ddlPresets "Сохранённые пресеты:" pos:[20,32] width:480 height:21 items:#()
    label lblPresetName "Имя:" pos:[20,68] width:55 height:18
    editText edtPresetName "" pos:[75,64] width:425 height:22

    button btnSavePreset "Сохранить / перезаписать" pos:[20,96] width:230 height:28
    button btnApplyPreset "Применить" pos:[270,96] width:230 height:28
    button btnDeletePreset "Удалить" pos:[20,132] width:230 height:26
    button btnRefreshPresets "Обновить список" pos:[270,132] width:230 height:26

    label lblPresetFile "INI:" pos:[20,166] width:480 height:18
    button btnDefaultPresetFile "Default INI" pos:[20,184] width:150 height:24
    button btnOpenPresetFile "Открыть INI..." pos:[185,184] width:150 height:24
    button btnNewPresetFile "Новый INI..." pos:[350,184] width:150 height:24

    groupBox gbMemory "Автопамять текущей сцены" pos:[10,225] width:500 height:120
    label lblMemory "Автопамять:" pos:[20,248] width:480 height:18
    button btnSaveMemory "Сохранить сейчас" pos:[20,276] width:150 height:28
    button btnLoadMemory "Загрузить" pos:[185,276] width:150 height:28
    button btnClearMemory "Очистить" pos:[350,276] width:150 height:28
    label lblMemoryHint "При закрытии окна генератора состояние сохраняется автоматически. Автозагрузка — только для той же .max сцены." pos:[20,314] width:480 height:26

    label lblPresetStatus "" pos:[20,355] width:480 height:42

    on forestPresetUI open do
    (
        forestLoadPresetManagerSettings()
        forestPresetRefreshUI()
    )

    on ddlPresets selected index do
    (
        if (index >= 1) and (index <= ddlPresets.items.count) do
        (
            local selectedName = ddlPresets.items[index]
            if selectedName != "<нет пресетов>" do
            (
                edtPresetName.text = selectedName
            )
        )
    )

    on btnSavePreset pressed do
    (
        local presetName = edtPresetName.text
        local presetFile = forestActivePresetFile()
        local alreadyExists = false

        if doesFileExist presetFile do
        (
            local oldCount = ""
            try (oldCount = getINISetting presetFile presetName "groupCount") catch()
            alreadyExists = (oldCount != "")
        )

        local allowSave = true
        if alreadyExists do
        (
            allowSave = forestStudioAsk ("Пресет \"" + presetName + "\" уже существует. Перезаписать?") title:"Генератор леса — пресеты"
        )

        if allowSave do
        (
            if forestSaveNamedPreset presetName then
            (
                lblPresetStatus.text = "Сохранено: " + presetName
                forestPresetRefreshUI()
            )
            else
            (
                lblPresetStatus.text = "Ошибка сохранения пресета."
            )
        )
    )

    on btnApplyPreset pressed do
    (
        local presetName = ""

        if (ddlPresets.selection >= 1) and (ddlPresets.selection <= ddlPresets.items.count) do
        (
            presetName = ddlPresets.items[ddlPresets.selection]
        )

        if presetName == "<нет пресетов>" do presetName = ""

        if presetName == "" then
        (
            forestStudioNotice "Выберите пресет." title:"Генератор леса — пресеты"
        )
        else
        (
            if forestApplyNamedPreset presetName then
            (
                lblPresetStatus.text = "Применён: " + presetName
                forestPresetRefreshUI()
            )
            else
            (
                lblPresetStatus.text = "Не удалось применить пресет."
            )
        )
    )

    on btnDeletePreset pressed do
    (
        local presetName = ""

        if (ddlPresets.selection >= 1) and (ddlPresets.selection <= ddlPresets.items.count) do
        (
            presetName = ddlPresets.items[ddlPresets.selection]
        )

        if (presetName != "") and (presetName != "<нет пресетов>") do
        (
            if forestStudioAsk ("Удалить пресет \"" + presetName + "\"?") title:"Генератор леса — пресеты" do
            (
                forestDeleteNamedPreset presetName
                lblPresetStatus.text = "Удалён: " + presetName
                forestPresetRefreshUI()
            )
        )
    )

    on btnRefreshPresets pressed do
    (
        forestPresetRefreshUI()
        lblPresetStatus.text = "Список обновлён."
    )

    on btnDefaultPresetFile pressed do
    (
        forestPresetCurrentFile = ""
        forestPresetLastName = ""
        forestSavePresetManagerSettings()
        forestPresetRefreshUI()
        lblPresetStatus.text = "Используется Default INI."
    )

    on btnOpenPresetFile pressed do
    (
        local selectedFile = getOpenFileName \
            caption:"Выберите INI с пресетами Forest Generator" \
            types:"INI (*.ini)|*.ini|Все файлы|*.*|"

        if selectedFile != undefined do
        (
            forestPresetCurrentFile = selectedFile
            forestPresetLastName = ""
            forestSavePresetManagerSettings()
            forestPresetRefreshUI()
            lblPresetStatus.text = "Открыт: " + filenameFromPath selectedFile
        )
    )

    on btnNewPresetFile pressed do
    (
        local selectedFile = getSaveFileName \
            caption:"Новый INI для пресетов Forest Generator" \
            types:"INI (*.ini)|*.ini|" \
            filename:"ForestGenerator_Presets.ini"

        if selectedFile != undefined do
        (
            forestPresetCurrentFile = selectedFile
            forestPresetLastName = ""
            forestSavePresetManagerSettings()
            forestPresetRefreshUI()
            lblPresetStatus.text = "Новый файл: " + filenameFromPath selectedFile
        )
    )

    on btnSaveMemory pressed do
    (
        forestCommitCurrentGroupUIQuiet()

        if forestSaveMemoryState quiet:false then
        (
            lblPresetStatus.text = "Автопамять сохранена."
            forestPresetRefreshUI()
        )
    )

    on btnLoadMemory pressed do
    (
        if forestLoadMemoryState quiet:false forceLoad:true then
        (
            forestSyncMainUIFromGlobals()
            lblPresetStatus.text = "Автопамять загружена."
            forestPresetRefreshUI()
        )
        else
        (
            lblPresetStatus.text = "Автопамять не найдена или не загружена."
        )
    )

    on btnClearMemory pressed do
    (
        if forestStudioAsk "Удалить сохранённую автопамять генератора?" title:"Генератор леса — память" do
        (
            forestClearMemoryState()
            lblPresetStatus.text = "Автопамять очищена."
            forestPresetRefreshUI()
        )
    )
)



rollout forestImportUI "STALKER SDK — Import .object"
(
    groupBox gbRoots "SDK rawdata paths" pos:[10,8] width:500 height:118
    label lblObjRoot "objects:" pos:[20,29] width:55 height:18
    editText edtSDKRoot "" pos:[78,25] width:332 height:20
    button btnSDKRoot "Выбрать" pos:[418,23] width:82 height:24
    label lblTexRoot "textures:" pos:[20,60] width:55 height:18
    editText edtTexturesRoot "" pos:[78,56] width:332 height:20
    button btnTexturesRoot "Выбрать" pos:[418,54] width:82 height:24
    label lblRootHint "Ожидаются ...\\sdk\\rawdata\\objects и ...\\sdk\\rawdata\\textures" pos:[20,92] width:470 height:18

    groupBox gbImporter "X-Ray Object Import backend" pos:[10,134] width:500 height:72
    editText edtImporter "" pos:[20,156] width:390 height:20
    button btnImporter "Выбрать" pos:[418,154] width:82 height:24
    label lblImportMode "Make Single ON | Scale 1.0 | Skin/Shape/Layers OFF | Maps ON" pos:[20,181] width:470 height:16

    button btnImportOne "Импортировать один .object" pos:[20,220] width:230 height:32
    button btnImportFolder "Импортировать все .object из папки" pos:[260,220] width:240 height:32
    label lblImportStatus "" pos:[20,260] width:480 height:32

    on forestImportUI open do
    (
        forestLoadSDKSettings()
        edtSDKRoot.text = forestSDKObjectsRoot
        edtTexturesRoot.text = forestSDKTexturesRoot

        local importerName = forestFindObjectImporterScript()
        edtImporter.text = importerName
    )

    on btnSDKRoot pressed do
    (
        local chosenRoot = getSavePath caption:"Выберите sdk\\rawdata\\objects" initialDir:edtSDKRoot.text

        if chosenRoot != undefined do
        (
            forestSaveSDKObjectsRoot chosenRoot
            edtSDKRoot.text = forestSDKObjectsRoot
        )
    )

    on btnTexturesRoot pressed do
    (
        local chosenRoot = getSavePath caption:"Выберите sdk\\rawdata\\textures" initialDir:edtTexturesRoot.text

        if chosenRoot != undefined do
        (
            forestSaveSDKTexturesRoot chosenRoot
            edtTexturesRoot.text = forestSDKTexturesRoot
        )
    )

    on btnImporter pressed do
    (
        local importerName = getOpenFileName caption:"Выберите xrTools.ObjectImport.ms" types:"MAXScript (*.ms)|*.ms|"

        if importerName != undefined do
        (
            forestSaveImporterScript importerName
            edtImporter.text = forestObjectImporterScript
        )
    )

    on btnImportOne pressed do
    (
        forestSaveSDKObjectsRoot edtSDKRoot.text
        forestSaveSDKTexturesRoot edtTexturesRoot.text
        forestSaveImporterScript edtImporter.text

        local startName = if forestSDKObjectsRoot == "" then "" else (forestSDKObjectsRoot + "\\")
        local objectName = getOpenFileName caption:"Импорт X-Ray .object" filename:startName types:"X-Ray Object (*.object)|*.object|"

        if objectName != undefined do
        (
            local importedNodes = forestImportObjectFiles #(objectName)
            lblImportStatus.text = "Импортировано: " + (importedNodes.count as string) + ". Объекты выделены."
        )
    )

    on btnImportFolder pressed do
    (
        forestSaveSDKObjectsRoot edtSDKRoot.text
        forestSaveSDKTexturesRoot edtTexturesRoot.text
        forestSaveImporterScript edtImporter.text

        local initialFolder = if forestSDKObjectsRoot == "" then "" else forestSDKObjectsRoot
        local objectFolder = getSavePath caption:"Папка с .object для импорта" initialDir:initialFolder

        if objectFolder != undefined do
        (
            local objectFiles = getFiles ((forestTrimTrailingSlash objectFolder) + "\\*.object")
            sort objectFiles

            if objectFiles.count == 0 then
            (
                forestStudioNotice "В выбранной папке нет *.object." title:"Forest Generator — Import"
            )
            else
            (
                local importedNodes = forestImportObjectFiles objectFiles
                lblImportStatus.text = "Импортировано: " + (importedNodes.count as string) + " из " + (objectFiles.count as string) + "."
            )
        )
    )
)


rollout forestLodUI "STALKER SDK — Forest LOD"
(
    spinner spnPlanes "Плоскостей:" pos:[20,18] width:215 height:18 range:[1,12,3] type:#integer
    spinner spnRenderSize "Размер текстуры:" pos:[270,18] width:225 height:18 range:[32,1024,128] type:#integer scale:32

    label lblTextureDir "Папка LOD-текстур:" pos:[20,52] width:160 height:18
    editText edtTextureDir "" pos:[20,72] width:390 height:20
    button btnTextureDir "Выбрать" pos:[418,70] width:82 height:24

    checkbox chkUseExisting "Использовать существующие TGA" pos:[20,108] width:230 height:18 checked:false
    checkbox chkDeleteOriginals "Удалить исходные модели после успешного LOD" pos:[20,134] width:350 height:18 checked:true

    button btnMakeLOD "СОЗДАТЬ LOD ИЗ ВЫДЕЛЕННЫХ" pos:[20,166] width:480 height:38
    label lblLodStatus "LOD сохраняет ref_name исходного .object." pos:[20,214] width:480 height:30

    on forestLodUI open do
    (
        forestLoadSDKSettings()
        edtTextureDir.text = forestLodTextureDir
    )

    on btnTextureDir pressed do
    (
        local chosenDir = getSavePath caption:"Папка для Forest LOD TGA" initialDir:edtTextureDir.text

        if chosenDir != undefined do
        (
            forestSaveLodTextureDir chosenDir
            edtTextureDir.text = forestLodTextureDir
        )
    )

    on btnMakeLOD pressed do
    (
        forestSaveLodTextureDir edtTextureDir.text

        local lodNodes = forestMakeLODsFromSelection \
            planeCount:spnPlanes.value \
            renderSize:spnRenderSize.value \
            textureDirectory:forestLodTextureDir \
            useExistingTexture:chkUseExisting.checked \
            deleteOriginals:chkDeleteOriginals.checked

        lblLodStatus.text = "Создано LOD: " + (lodNodes.count as string) + ". Результат выделен, слой FG_LOD_Sources."
    )
)


rollout forestExportUI "STALKER SDK — Export scene_object.part"
(
    label lblPart "scene_object.part:" pos:[20,16] width:150 height:18
    editText edtPart "" pos:[20,36] width:390 height:20
    button btnPart "Выбрать" pos:[418,34] width:82 height:24

    label lblExportRoot "SDK objects root:" pos:[20,70] width:150 height:18
    editText edtExportRoot "" pos:[20,90] width:390 height:20
    button btnExportRoot "Выбрать" pos:[418,88] width:82 height:24

    radioButtons rbExportMode "Объекты:" labels:#("Все Forest_* слои", "Только выделенные") columns:2 pos:[20,126] default:1
    label lblPrefix "Префикс имени (не меняет reference_name):" pos:[20,162] width:275 height:18
    editText edtPrefix "" pos:[300,158] width:200 height:22

    button btnValidateExport "ПРОВЕРИТЬ" pos:[20,198] width:230 height:32
    button btnDoExport "ЭКСПОРТ В .PART" pos:[260,198] width:240 height:32

    label lblExportStatus "" pos:[20,242] width:480 height:55
    label lblBackup "Перед записью автоматически создаётся backup исходного .part." pos:[20,302] width:480 height:18

    fn currentExportNodes =
    (
        if rbExportMode.state == 1 then
            forestCollectGeneratedNodes()
        else
            (for selectedNode in selection where \
                (isValidNode selectedNode) and \
                (superClassOf selectedNode == GeometryClass) and \
                (selectedNode.parent == undefined) collect selectedNode)
    )

    on forestExportUI open do
    (
        forestLoadSDKSettings()
        edtExportRoot.text = forestSDKObjectsRoot
        edtPart.text = forestLastScenePart
    )

    on btnPart pressed do
    (
        local seedName = if edtPart.text == "" then "scene_object.part" else edtPart.text
        local partName = getOpenFileName caption:"Выберите scene_object.part" filename:seedName types:"X-Ray SDK Level Part (*.part)|*.part|"

        if partName != undefined do
        (
            forestSaveScenePart partName
            edtPart.text = forestLastScenePart
        )
    )

    on btnExportRoot pressed do
    (
        local chosenRoot = getSavePath caption:"Выберите sdk\\rawdata\\objects" initialDir:edtExportRoot.text

        if chosenRoot != undefined do
        (
            forestSaveSDKObjectsRoot chosenRoot
            edtExportRoot.text = forestSDKObjectsRoot
        )
    )

    on btnValidateExport pressed do
    (
        forestSaveSDKObjectsRoot edtExportRoot.text
        local exportNodes = currentExportNodes()
        local validation = forestValidateExportNodes exportNodes

        if validation[2].count == 0 then
        (
            lblExportStatus.text = "OK. Готово к экспорту: " + (validation[1].count as string) + " объектов."
            format "Forest Export validation OK: % object(s).\n" validation[1].count
        )
        else
        (
            lblExportStatus.text = "Ошибок: " + (validation[2].count as string) + ". Подробности в Listener."
            format "Forest Export validation issues:\n"
            forestPrintIssues validation[2]
        )
    )

    on btnDoExport pressed do
    (
        forestSaveSDKObjectsRoot edtExportRoot.text
        forestSaveScenePart edtPart.text

        local exportNodes = currentExportNodes()

        forestExportNodesToPart exportNodes forestLastScenePart prefixText:edtPrefix.text
    )
)


/* ------------------------------------------------------------
   ОСНОВНОЙ ИНТЕРФЕЙС
   ------------------------------------------------------------ */


/* ============================================================
   FOREST ASSET LIBRARY v0.1 (3ds Max 2024)
   Динамический каталог из всех .object в SDK\\rawdata\\objects\\trees; группы содержат ref_name.
   .NET ListView для настоящих Windows иконок; THM не декодируется
   на этой стадии. В папке PNG-кэша можно положить PNG для каждого
   объекта, схема именования: trees_new_trees_trees_elka_1_01.png
   ============================================================ */

global forestLibraryUI
try (destroyDialog forestLibraryUI) catch()
global forestLibraryCatalog = #()  -- scanned from SDK\rawdata\objects\trees, not a fixed list

fn forestLibraryScanFolder folder objectsRoot items =
(
    local folderPath = forestTrimTrailingSlash folder
    local files = #()
    try (files = getFiles (folderPath + "\\*.object")) catch()
    for sourceFile in files do
    (
        local stem = (getFilenamePath sourceFile) + (getFilenameFile sourceFile)
        if stem.count > (objectsRoot.count + 1) do
        (
            local reference = substring stem (objectsRoot.count + 2) -1
            reference = substituteString reference "/" "\\"
            appendIfUnique items reference
        )
    )
    local directories = #()
    try (directories = getDirectories (folderPath + "\\*")) catch()
    for directory in directories do forestLibraryScanFolder directory objectsRoot items
    items
)

fn forestLibraryDiscoverModels =
(
    local root = forestTrimTrailingSlash forestSDKObjectsRoot
    local treeDir = root + "\\trees"
    local results = #()
    if doesDirectoryExist treeDir do
    (
        forestLibraryScanFolder treeDir root results
        sort results
    )
    forestLibraryCatalog = results
    format "Forest Studio: SDK trees library = % .object files, root = %\n" results.count treeDir
    results
)

fn forestLibraryWriteDynamicCatalog =
(
    local cacheRoot = (getDir #userScripts) + "\\ForestGenerator"
    makeDir cacheRoot all:true
    local filePath = cacheRoot + "\\library_catalog.txt"
    local fs = createFile filePath
    if fs == undefined then return undefined
    for modelRef in forestLibraryCatalog do format "%\n" modelRef to:fs
    close fs
    filePath
)

global forestLibraryImageList = undefined
global forestLibraryOwnedBitmaps = #() -- Удерживаем .NET Bitmap живыми до уничтожения ImageList.
global forestLibraryLoadedCategory = "Все"
global forestLibrarySelectionGuard = false
global forestLibraryThumbnailToolPath = ""
try (forestLibraryThumbnailToolPath = (getFilenamePath (getSourceFileName())) + "forest_thm_cache.py") catch()

fn forestLibraryPyString input =
(
    "\"" + (substituteString input "\\" "/") + "\""
)

fn forestLibraryCreateThumbnails =
(
    local root = forestTrimTrailingSlash forestSDKObjectsRoot
    if not doesDirectoryExist root then
    (
        forestStudioNotice "Укажи корректную папку sdk\\rawdata\\objects." title:"Forest Library — THM"
        return false
    )
    if not doesFileExist forestLibraryThumbnailToolPath do
    (
        local scriptName = getOpenFileName caption:"Найди forest_thm_cache.py из комплекта" types:"Python (*.py)|*.py|"
        if scriptName == undefined then return false
        forestLibraryThumbnailToolPath = scriptName
    )
    local manifestName = (forestLibraryCacheDirectory()) + "\\asset_manifest.txt"
    local out = createFile manifestName
    if out == undefined then
    (
        forestStudioNotice "Не удалось создать список миниатюр в UserScripts." title:"Forest Library — THM"
        return false
    )
    for refName in forestLibraryCatalog do format "%\n" refName to:out
    close out
    local cmd = "import runpy; runpy.run_path(" + \
        (forestLibraryPyString forestLibraryThumbnailToolPath) + \
        ")[\"build_cache\"](" + \
        (forestLibraryPyString root) + ", " + \
        (forestLibraryPyString (forestLibraryCacheDirectory())) + ", " + \
        (forestLibraryPyString manifestName) + ")"
    local ok = false
    try
    (
        ok = ((python.Execute cmd clearUndoBuffer:false) == #success)
    )
    catch
    (
        format "THM cache error: %\n" (getCurrentException())
    )
    if not ok then
    (
        forestStudioNotice "Ошибка конвертации THM. Открой MAXScript Listener — там будет подробность." title:"Forest Library — THM"
    )
    ok
)

fn forestLibraryCategory refName =
(
    local ref = toLower refName
    if (findString ref "\\new_stone\\") != undefined then "Камни"
    else if ((findString ref "\\cane\\") != undefined) or ((findString ref "kamish") != undefined) then "Камыш"
    else if (findString ref "bush") != undefined then "Кусты"
    else if ((findString ref "rostki") != undefined) or ((findString ref "root") != undefined) or ((findString ref "branch") != undefined) or ((findString ref "valejnik") != undefined) or ((findString ref "spil") != undefined) or ((findString ref "tina") != undefined) then "Подлесок"
    else "Деревья"
)

fn forestLibraryCacheDirectory =
(
    local p = (getDir #userScripts) + "\\ForestGenerator\\Thumbnails"
    try (makeDir p all:true) catch()
    p
)

-- Clear PNG cache for all objects currently discovered in SDK, plus
-- the decoder's cache stamp/manifest. Never touch presets or source THMs.
fn forestLibraryClearThumbnailCache =
(
    local cacheDir = forestLibraryCacheDirectory()
    local removedCount = 0
    local failureCount = 0
    -- This directory is dedicated to generated THM PNG thumbnails.
    -- Delete stale PNG from models removed/moved since the last scan too.
    local cachedPNGs = #()
    try (cachedPNGs = getFiles (cacheDir + "\\*.png")) catch()
    for cacheName in cachedPNGs do
    (
        if deleteFile cacheName then removedCount += 1 else failureCount += 1
    )
    for auxName in #( "asset_manifest.txt", ".forest_thm_v2" ) do
    (
        local auxPath = cacheDir + "\\" + auxName
        if doesFileExist auxPath do
        (
            if deleteFile auxPath then removedCount += 1 else failureCount += 1
        )
    )
    format "Forest Studio: cache cleanup removed %, errors %.\n" removedCount failureCount
    #(removedCount, failureCount)
)

fn forestLibraryCacheName refName =
(
    local result = forestNormalizeRefName refName
    result = substituteString result "\\" "_"
    (forestLibraryCacheDirectory()) + "\\" + result + ".png"
)

fn forestLibraryObjectPath refName =
(
    (forestTrimTrailingSlash forestSDKObjectsRoot) + "\\" + (forestNormalizeRefName refName) + ".object"
)

fn forestLibraryFindLOD refName =
(
    local result = undefined
    local nodes = getObjectsByLayer "FG_LOD_Sources"
    for obj in nodes do
    (
        if result == undefined do
        (
            local candidateRef = forestGetRefName obj
            if (stricmp candidateRef refName) == 0 do result = obj
        )
    )
    result
)

fn forestLibraryIsCatalogRef refName =
(
    for candidate in forestLibraryCatalog do
    (
        if (stricmp candidate refName) == 0 do return true
    )
    false
)

fn forestLibraryRefsForGroup group =
(
    local found = #()
    if group.usePresetSources then
    (
        for refName in group.presetSourceRefs do
        (
            if refName != "" do
            (
                local exists = false
                for x in found do (if (stricmp x refName) == 0 do exists = true)
                if not exists do append found refName
            )
        )
    )
    else
    (
        for obj in (getObjectsByLayer group.layerName) do
        (
            local refName = forestGetRefName obj
            if refName != "" do
            (
                local exists = false
                for x in found do (if (stricmp x refName) == 0 do exists = true)
                if not exists do append found refName
            )
        )
    )
    found
)

fn forestLibraryTurnGroupExplicit group =
(
    if not group.usePresetSources do
    (
        local existingRefs = forestLibraryRefsForGroup group
        group.presetSourceNames = #()
        group.presetSourceRefs = #()
        group.sourceWeights = #()
        for refName in existingRefs do
        (
            local nameOfSource = "LOD_" + (getFilenameFile refName)
            append group.presetSourceNames nameOfSource
            append group.presetSourceRefs refName
            append group.sourceWeights 100.0
        )
        group.usePresetSources = true
    )
    true
)

fn forestLibraryAddRefs groupIndex refs =
(
    if (groupIndex < 1) or (groupIndex > forestGroupsList.count) then return 0
    local grp = forestGroupsList[groupIndex]
    forestLibraryTurnGroupExplicit grp
    local appended = 0
    for refName in refs do
    (
        if forestLibraryIsCatalogRef refName do
        (
            local present = false
            for currentRef in grp.presetSourceRefs do
            (
                if (stricmp currentRef refName) == 0 do present = true
            )
            if not present do
            (
                append grp.presetSourceNames ("LOD_" + (getFilenameFile refName))
                append grp.presetSourceRefs refName
                append grp.sourceWeights 100.0
                appended += 1
            )
        )
    )
    if appended > 0 do forestSaveMemoryState quiet:true
    appended
)

fn forestLibraryDeleteRef groupIndex removeIndex =
(
    if (groupIndex < 1) or (groupIndex > forestGroupsList.count) then return false
    local grp = forestGroupsList[groupIndex]
    forestLibraryTurnGroupExplicit grp
    if (removeIndex < 1) or (removeIndex > grp.presetSourceRefs.count) then return false
    deleteItem grp.presetSourceRefs removeIndex
    if removeIndex <= grp.sourceWeights.count do deleteItem grp.sourceWeights removeIndex
    if removeIndex <= grp.presetSourceNames.count do deleteItem grp.presetSourceNames removeIndex
    forestSaveMemoryState quiet:true
    true
)

fn forestLibrarySetSourceWeight groupIndex sourceIndex weightValue =
(
    if (groupIndex < 1) or (groupIndex > forestGroupsList.count) then return false
    local grp = forestGroupsList[groupIndex]
    forestLibraryTurnGroupExplicit grp
    if (sourceIndex < 1) or (sourceIndex > grp.presetSourceRefs.count) then return false
    while grp.sourceWeights.count < grp.presetSourceRefs.count do append grp.sourceWeights 100.0
    grp.sourceWeights[sourceIndex] = amin 100.0 (amax 0.0 weightValue)
    forestSaveMemoryState quiet:true
    true
)

fn forestLibraryPrepareRefs refs =
(
    /* Подготовка выполняется строго для нужных моделей, без импорта каталога целиком. */
    if refs.count < 1 then return #()
    forestLoadSDKSettings()
    if (forestSDKObjectsRoot == "") or (not doesDirectoryExist forestSDKObjectsRoot) then
    (
        forestStudioNotice "Укажи существующую папку sdk\\rawdata\\objects вверху библиотеки." title:"Forest Library"
        return #()
    )
    local filesToImport = #()
    local missing = #()
    local countReady = 0
    for refName in refs do
    (
        if (forestLibraryFindLOD refName) != undefined then
        (
            countReady += 1
        )
        else
        (
            local filePath = forestLibraryObjectPath refName
            if doesFileExist filePath then
                append filesToImport filePath
            else
                append missing refName
        )
    )
    if missing.count > 0 then
    (
        local report = "Не найдены .object в SDK:\\n"
        for j = 1 to (amin missing.count 8) do report += missing[j] + "\\n"
        if missing.count > 8 do report += "... +" + ((missing.count - 8) as string)
        forestStudioNotice report title:"Forest Library"
    )
    if filesToImport.count == 0 then
    (
        format "Asset Library: no import needed, LOD ready: %\n" countReady
        return #()
    )
    local importedNodes = forestImportObjectFiles filesToImport
    if importedNodes.count == 0 then return #()
    if not doesDirectoryExist forestLodTextureDir do
    (
        try (makeDir forestLodTextureDir all:true) catch()
    )
    if not doesDirectoryExist forestLodTextureDir then
    (
        forestStudioNotice "Не удалось создать папку LOD-текстур. Исходные модели оставлены в сцене." title:"Forest Library"
        return #()
    )
    select importedNodes
    local created = forestMakeLODsFromSelection planeCount:3 renderSize:128 textureDirectory:forestLodTextureDir useExistingTexture:true deleteOriginals:true
    format "Asset Library: imported % models, created % LODs, already had % LODs.\n" importedNodes.count created.count countReady
    created
)

fn forestLibraryPrepareMissingForGroups =
(
    local allRefs = #()
    for grp in forestGroupsList do
    (
        if grp.usePresetSources do
        (
            for refName in grp.presetSourceRefs do
            (
                if forestLibraryIsCatalogRef refName do
                (
                    local exists = false
                    for r in allRefs do (if (stricmp r refName) == 0 do exists = true)
                    if not exists do append allRefs refName
                )
            )
        )
    )
    local missing = #()
    for refName in allRefs do (if (forestLibraryFindLOD refName) == undefined do append missing refName)
    if missing.count == 0 then return true
    local answer = forestStudioAsk ("Необходимо подготовить " + (missing.count as string) + " LOD из библиотеки.\nИмпортировать нужные модели и создать LOD перед генерацией?") title:"Forest Library"
    if not answer then return false
    forestLibraryPrepareRefs missing
    for refName in missing do
    (
        if (forestLibraryFindLOD refName) == undefined then
        (
            forestStudioNotice ("LOD не подготовлен: " + refName + "\nГенерация отменена. Проверь Listener.") title:"Forest Library"
            return false
        )
    )
    true
)

/* Список источников по ref_name: сначала оригинальный LOD-слой, затем старый поиск.
   Не выбираем посаженные Forest_* instances в качестве источника нового леса. */
fn forestLibraryFindSourceByRef refName =
(
    local lod = forestLibraryFindLOD refName
    if lod != undefined then return lod
    local original = getObjectsByLayer "FG_Imported_Originals"
    for node in original do (if (stricmp (forestGetRefName node) refName) == 0 do return node)
    undefined
)

/* UI: размеры фиксированные, чтобы избежать несовместимых AutoScale/Anchor в Max. */
rollout forestLibraryUI "FOREST GENERATOR — Asset Library v0.1.2" width:1130 height:736
(
    groupBox gbPath "SDK ASSET LIBRARY  •  статичный каталог 213 моделей" pos:[12,8] width:1106 height:67
    editText edtRoot "Objects root:" pos:[23,29] width:916 height:20 readOnly:true
    button btnPickRoot "Папка SDK..." pos:[950,26] width:155 height:26

    editText edtSearch "Поиск:" pos:[20,87] width:455 height:23
    dropdownlist ddlCategory "Категория:" pos:[500,87] width:222 height:23 items:#("Все", "Деревья", "Кусты", "Камни", "Камыш", "Подлесок") selection:1
    button btnRefresh "Обновить" pos:[738,86] width:93 height:26
    label lblVisible "" pos:[853,91] width:260 height:18

    dotNetControl lvAssets "System.Windows.Forms.ListView" pos:[20,121] width:704 height:497
    label lblAssetsHelp "Ctrl/Shift — выделить несколько. Двойной клик не импортирует объект." pos:[22,625] width:705 height:18

    groupBox gbGroups "СОСТАВ ГРУППЫ" pos:[736,119] width:381 height:502
    dropdownlist ddlGroup "Группа:" pos:[748,146] width:356 height:25 items:#()
    button btnNewGroup "+ Группа" pos:[747,178] width:106 height:26
    button btnDeleteGroup "Удалить группу" pos:[862,178] width:122 height:26
    button btnReloadGroups "↻" pos:[996,178] width:108 height:26
    label lblGroupMembers "Список объектов этой группы:" pos:[748,214] width:335 height:18
    listbox lbMembers "" pos:[747,236] width:350 height:13 items:#()
    button btnAdd "+ Добавить выбранные в группу" pos:[747,474] width:353 height:33
    button btnRemove "− Удалить из группы" pos:[747,515] width:353 height:28
    label lblSelected "Выбрано: 0" pos:[747,553] width:348 height:18
    label lblLOD "LOD: 0 готово" pos:[747,576] width:348 height:18

    groupBox gbActions "ПОДГОТОВКА АССЕТОВ" pos:[12,648] width:1106 height:77
    button btnPrepareSelected "Подготовить выделенные" pos:[22,671] width:253 height:33
    button btnPrepareGroup "Подготовить группу" pos:[286,671] width:245 height:33
    button btnThumbnails "THM → иконки" pos:[542,671] width:244 height:33
    button btnSave "Память и пресеты" pos:[797,671] width:307 height:33

    /* MAXScript компилирует rollout по порядку: вспомогательная функция
       должна быть объявлена РАНЬШЕ функции, которая её вызывает.
       Иначе ссылка из fillGroups() превращается в local undefined. */
    fn fillMembers =
    (
        local values = #()
        local i = ddlGroup.selection
        -- Пустой каталог групп допустим: окно должно открываться до создания группы.
        if i == undefined do i = 0
        if (i > 0) and (i <= forestGroupsList.count) do
        (
            local refs = forestLibraryRefsForGroup forestGroupsList[i]
            for refName in refs do append values refName
        )
        lbMembers.items = values
        if forestGroupsList.count == 0 then
        (
            lblGroupMembers.text = "Групп пока нет — нажми '+ Группа'"
        )
        else
        (
            lblGroupMembers.text = "Объекты группы: " + (values.count as string)
        )
    )

    fn fillGroups =
    (
        local names = #()
        for g in forestGroupsList do append names g.groupName
        ddlGroup.items = names
        if names.count > 0 then
        (
            local index = forestCurrentGroupIndex
            if index == undefined do index = 1
            if index < 1 do index = 1
            if index > names.count do index = names.count
            ddlGroup.selection = index
        )
        fillMembers()
    )

    fn chosenRefs =
    (
        local items = #()
        if lvAssets.SelectedItems.Count > 0 do
        (
            for i = 0 to (lvAssets.SelectedItems.Count - 1) do
            (
                local item = lvAssets.SelectedItems.Item[i]
                append items (item.Tag as string)
            )
        )
        items
    )

    fn updateSelected =
    (
        local selected = chosenRefs()
        lblSelected.text = "Выбрано в каталоге: " + (selected.count as string)
        local readyCount = 0
        for refName in selected do (if forestLibraryFindLOD refName != undefined do readyCount += 1)
        lblLOD.text = "Из выделенных LOD готово: " + (readyCount as string)
    )

    fn makePlaceholder categoryName =
    (
        local tile = dotNetObject "System.Drawing.Bitmap" 96 96
        local draw = (dotNetClass "System.Drawing.Graphics").FromImage tile
        local c = dotNetClass "System.Drawing.Color"
        local bg = c.FromArgb 53 70 61
        if categoryName == "Камни" do bg = c.FromArgb 76 78 85
        if categoryName == "Кусты" do bg = c.FromArgb 51 86 66
        if categoryName == "Камыш" do bg = c.FromArgb 100 87 56
        if categoryName == "Подлесок" do bg = c.FromArgb 84 74 59
        draw.Clear bg
        try
        (
            local letter = "TREE"
            if categoryName == "Камни" do letter = "STONE"
            if categoryName == "Кусты" do letter = "BUSH"
            if categoryName == "Камыш" do letter = "CANE"
            if categoryName == "Подлесок" do letter = "WOOD"
            local font = dotNetObject "System.Drawing.Font" "Segoe UI" 11.0
            local brush = dotNetObject "System.Drawing.SolidBrush" c.White
            draw.DrawString letter font brush 14.0 38.0
            brush.Dispose()
            font.Dispose()
        )
        catch()
        draw.Dispose()
        tile
    )

    /* В .NET ImageList может откладывать создание внутреннего image handle
       до подключения к ListView. Нельзя Dispose() у Bitmap сразу после
       Images.Add — ListView позже попытается прочитать уже освобождённое
       изображение и выдаст ArgumentException: Parameter is not valid.
       Держим bitmap-объекты живыми всё время существования ImageList. */
    fn freeImages =
    (
        -- Сначала отвязываем ImageList от ListView, и только потом удаляем.
        try (lvAssets.LargeImageList = undefined) catch()
        if forestLibraryImageList != undefined do
        (
            try (forestLibraryImageList.Dispose()) catch()
            forestLibraryImageList = undefined
        )
        for bitmapRef in forestLibraryOwnedBitmaps do
        (
            try (bitmapRef.Dispose()) catch()
        )
        forestLibraryOwnedBitmaps = #()
    )

    fn loadImages =
    (
        freeImages()
        forestLibraryImageList = dotNetObject "System.Windows.Forms.ImageList"
        forestLibraryImageList.ImageSize = dotNetObject "System.Drawing.Size" 96 96
        forestLibraryImageList.ColorDepth = (dotNetClass "System.Windows.Forms.ColorDepth").Depth32Bit
        local fallbacks = 0
        local pngLoaded = 0
        for refName in forestLibraryCatalog do
        (
            local cacheName = forestLibraryCacheName refName
            local bmp = undefined
            local imageFromPNG = false
            if doesFileExist cacheName do
            (
                try
                (
                    local loaded = (dotNetClass "System.Drawing.Image").FromFile cacheName
                    -- Clone() отделяет картинку от файла, сам файл закрывается.
                    bmp = loaded.Clone()
                    loaded.Dispose()
                    imageFromPNG = true
                )
                catch
                (
                    try (loaded.Dispose()) catch()
                    bmp = undefined
                    format "Forest Library: повреждённый PNG-кэш: %\n" cacheName
                )
            )
            if bmp == undefined do
            (
                bmp = makePlaceholder (forestLibraryCategory refName)
                fallbacks += 1
            )
            -- НЕ вызывать bmp.Dispose здесь: ImageList ещё может не иметь handle.
            local addOK = false
            try
            (
                forestLibraryImageList.Images.Add bmp
                addOK = true
            )
            catch
            (
                format "Forest Library: ошибка добавления иконки: %\n" refName
            )
            if not addOK do
            (
                -- Отдельная иконка-заглушка вместо нечитабельного изображения.
                try (bmp.Dispose()) catch()
                bmp = makePlaceholder (forestLibraryCategory refName)
                forestLibraryImageList.Images.Add bmp
                if imageFromPNG do fallbacks += 1
                imageFromPNG = false
            )
            if imageFromPNG do pngLoaded += 1
            append forestLibraryOwnedBitmaps bmp
        )
        -- Список должен иметь ровно по одной иконке на каждый ref_name.
        if forestLibraryImageList.Images.Count != forestLibraryCatalog.count then
        (
            format "Forest Library: неверное число иконок (% вместо %).\n" forestLibraryImageList.Images.Count forestLibraryCatalog.count
        )
        try
        (
            lvAssets.LargeImageList = forestLibraryImageList
            format "Forest Library: % PNG, % заглушек, всего % иконок.\n" pngLoaded fallbacks forestLibraryImageList.Images.Count
        )
        catch
        (
            -- Не делаем библиотеку недоступной из-за GDI+: каталог работает без иконок.
            format "Forest Library: не удалось подключить .NET ImageList. Каталог доступен без миниатюр.\n"
            try (lvAssets.LargeImageList = undefined) catch()
            try (lvAssets.View = (dotNetClass "System.Windows.Forms.View").List) catch()
        )
    )

    fn fillCatalog =
    (
        local categoryName = ddlCategory.selected
        local term = toLower edtSearch.text
        lvAssets.BeginUpdate()
        lvAssets.Items.Clear()
        local shown = 0
        for index = 1 to forestLibraryCatalog.count do
        (
            local refName = forestLibraryCatalog[index]
            local category = forestLibraryCategory refName
            if ((categoryName == "Все") or (categoryName == category)) and ((term == "") or ((findString (toLower refName) term) != undefined)) do
            (
                local item = dotNetObject "System.Windows.Forms.ListViewItem" (getFilenameFile refName)
                item.ImageIndex = index - 1
                item.Tag = refName
                item.ToolTipText = refName
                lvAssets.Items.Add item
                shown += 1
            )
        )
        lvAssets.EndUpdate()
        lblVisible.text = "Показано: " + (shown as string) + " / " + (forestLibraryCatalog.count as string)
        updateSelected()
    )

    on forestLibraryUI open do
    (
        forestLoadSDKSettings()
        edtRoot.text = forestSDKObjectsRoot
        lvAssets.View = (dotNetClass "System.Windows.Forms.View").LargeIcon
        lvAssets.MultiSelect = true
        lvAssets.HideSelection = false
        lvAssets.ShowItemToolTips = true
        lvAssets.LabelWrap = true
        lvAssets.UseCompatibleStateImageBehavior = false
        loadImages()
        fillGroups()
        fillCatalog()
    )

    on forestLibraryUI close do
    (
        freeImages()
    )

    on btnPickRoot pressed do
    (
        local chosen = getSavePath caption:"Выбери sdk\\rawdata\\objects" initialDir:forestSDKObjectsRoot
        if chosen != undefined do
        (
            forestSaveSDKObjectsRoot chosen
            edtRoot.text = forestSDKObjectsRoot
            fillCatalog()
        )
    )
    on edtSearch changed value do fillCatalog()
    on ddlCategory selected i do fillCatalog()
    on btnRefresh pressed do
    (
        loadImages()
        fillGroups()
        fillCatalog()
    )
    on lvAssets SelectedIndexChanged sender arg do updateSelected()
    on ddlGroup selected i do
    (
        if (i > 0) and (i <= forestGroupsList.count) do
        (
            if forestCurrentGroupIndex > 0 do forestCommitCurrentGroupUIQuiet()
            forestCurrentGroupIndex = i
            forestLoadGroupToUI i
            fillMembers()
        )
    )
    on btnNewGroup pressed do
    (
        forestCommitCurrentGroupUIQuiet()
        forestCreateGroup()
        fillGroups()
        forestSaveMemoryState quiet:true
    )
    on btnDeleteGroup pressed do
    (
        if (ddlGroup.selection > 0) and (ddlGroup.selection <= forestGroupsList.count) do
        (
            if forestStudioAsk ("Удалить группу " + forestGroupsList[ddlGroup.selection].groupName + "?") title:"Forest Library" do
            (
                forestCurrentGroupIndex = ddlGroup.selection
                forestDeleteCurrentGroup()
                fillGroups()
                forestSaveMemoryState quiet:true
            )
        )
    )
    on btnReloadGroups pressed do fillGroups()
    on btnAdd pressed do
    (
        local refs = chosenRefs()
        local i = ddlGroup.selection
        if i < 1 then
        (
            forestStudioNotice "Создай или выбери группу." title:"Forest Library"
        )
        else if refs.count == 0 then
        (
            forestStudioNotice "Выдели модели в каталоге (Ctrl / Shift)." title:"Forest Library"
        )
        else
        (
            if forestCurrentGroupIndex == i do forestCommitCurrentGroupUIQuiet()
            local added = forestLibraryAddRefs i refs
            fillMembers()
            format "Asset Library: added % assets to group %\n" added forestGroupsList[i].groupName
        )
    )
    on btnRemove pressed do
    (
        local i = ddlGroup.selection
        if (i > 0) and (lbMembers.selection > 0) do
        (
            forestLibraryDeleteRef i lbMembers.selection
            fillMembers()
        )
    )
    on btnPrepareSelected pressed do
    (
        forestLibraryPrepareRefs (chosenRefs())
        updateSelected()
    )
    on btnPrepareGroup pressed do
    (
        local i = ddlGroup.selection
        if i > 0 do
        (
            forestLibraryPrepareRefs (forestLibraryRefsForGroup forestGroupsList[i])
            updateSelected()
        )
    )
    on btnThumbnails pressed do
    (
        if forestLibraryCreateThumbnails() do
        (
            loadImages()
            fillCatalog()
            forestStudioNotice "Миниатюры обновлены. Ошибки отдельных THM смотри в Listener." title:"Forest Library — THM"
        )
    )
    on btnSave pressed do
    (
        forestSaveMemoryState quiet:false
        try (destroyDialog forestPresetUI) catch()
        createDialog forestPresetUI width:520 height:410
    )
)


rollout forestUI "Генератор леса"
(
    groupBox gbTerrain "Террейн и масштаб сцены" pos:[10, 8] width:460 height:108
    editText edtTerrain "" pos:[20, 30] width:320 height:20 readOnly:true
    button btnPickTerrain "Выбрать" pos:[350, 28] width:105 height:24
    checkbox chkUseSubObj "Use SubObject" pos:[20, 58] width:150 height:18 checked:false

    label lblSceneScale "1 игровой метр =" pos:[20, 84] width:105 height:18
    spinner spnSceneUnits "" pos:[128, 80] width:105 height:18 range:[0.0001,1000000.0,1.0] type:#float scale:0.1 fieldWidth:72
    label lblSceneUnits "units" pos:[238, 84] width:38 height:18
    button btnUseSystemScale "Из System Units" pos:[290, 78] width:165 height:24

    groupBox gbMask "Маска" pos:[10, 124] width:460 height:100
    button btnLoadMask "Загрузить маску" pos:[20, 146] width:135 height:26
    button btnEyedropper "Пипетка" pos:[165, 146] width:95 height:26 enabled:false
    label lblMaskInfo "Маска не загружена" pos:[20, 178] width:430 height:18
    label lblAlphaInfo "Alpha: —" pos:[20, 196] width:430 height:18

    groupBox gbGroups "Группы" pos:[10, 232] width:460 height:205
    button btnCreateGroup "Создать группу" pos:[20, 254] width:135 height:26
    button btnDeleteGroup "Удалить выбранную" pos:[165, 254] width:145 height:26
    listbox lbGroups "" pos:[20, 288] width:440 height:8

    groupBox gbSettings "Настройки группы" pos:[10, 446] width:460 height:366

    label lblGroupName "Имя:" pos:[20, 472] width:70 height:18
    editText edtGroupName "" pos:[100, 468] width:350 height:22

    label lblLayer "Слой:" pos:[20, 502] width:70 height:18
    dropdownlist ddlLayer "" pos:[100, 498] width:350 height:21 items:#()

    colorPicker cpColorPicker "Цвет маски:" pos:[20, 530] width:210 height:18 color:(color 255 0 0)

    spinner spnDensity "Плотность, шт/га:" pos:[245, 528] width:205 height:18 range:[0.1,100000.0,300.0] type:#float scale:10.0

    spinner spnScaleMin "Масштаб мин:" pos:[20, 558] width:205 height:18 range:[0.1,5.0,0.8] type:#float scale:0.01
    spinner spnScaleMax "Масштаб макс:" pos:[245, 558] width:205 height:18 range:[0.1,5.0,1.2] type:#float scale:0.01

    checkbox chkRandomRot "Случайный поворот по Y (вокруг Z)" pos:[20, 588] width:245 height:18 checked:true
    checkbox chkAlignNormal "Выравнивание по нормали" pos:[275, 588] width:175 height:18 checked:true

    spinner spnTilt "Сила наклона:" pos:[20, 618] width:205 height:18 range:[0.0,30.0,5.0] type:#float scale:0.1
    spinner spnDistInside "Дистанция внутри, м:" pos:[245, 618] width:205 height:18 range:[0.0,100.0,2.0] type:#float scale:0.1

    subrollout srDistances "Дистанции до других групп, м" pos:[20, 648] width:430 height:115

    button btnApply "Применить настройки" pos:[20, 775] width:300 height:27
    button btnPresetManager "Пресеты / память" pos:[330, 775] width:120 height:27

    button btnGenerate "СГЕНЕРИРОВАТЬ" pos:[10, 825] width:460 height:42

    groupBox gbSDK "STALKER SDK" pos:[10, 875] width:460 height:72
    button btnSDKImport "Импорт" pos:[20, 899] width:100 height:30
    button btnSDKLOD "LOD" pos:[130, 899] width:100 height:30
    button btnSDKExport "Экспорт .part" pos:[240, 899] width:100 height:30
    button btnLibrary "БИБЛИОТЕКА" pos:[350, 899] width:105 height:30

    on forestUI open do
    (
        edtTerrain.text = ""
        chkUseSubObj.checked = forestUseSubObj
        spnSceneUnits.value = forestUnitsPerGameMeter
        btnEyedropper.enabled = (forestMaskBitmap != undefined)

        if forestMaskBitmap == undefined then
        (
            lblAlphaInfo.text = "Alpha: —"
        )
        else
        (
            local openAlphaStats = forestGetMaskAlphaStats forestMaskBitmap sampleCount:32

            if openAlphaStats[1] then
            (
                lblAlphaInfo.text = "Alpha: ДА | sampled min=" + \
                    ((openAlphaStats[2] as integer) as string) + \
                    " max=" + ((openAlphaStats[3] as integer) as string)
            )
            else
            (
                lblAlphaInfo.text = "Alpha: НЕТ — плотность по Alpha не работает"
            )
        )

        forestRefreshLayerDropdown()
        forestRefreshGroupsList selectIndex:0
        forestSyncMainUIFromGlobals()
    )

    on btnPickTerrain pressed do
    (
        local picked = pickObject prompt:"Выберите объект террейна" filter:forestGeometryFilter

        if (picked != undefined) and (picked != #escape) and (isValidNode picked) do
        (
            forestTerrain = picked
            edtTerrain.text = picked.name
            forestSaveMemoryState quiet:true
        )
    )

    on chkUseSubObj changed state do
    (
        forestUseSubObj = state
        forestSaveMemoryState quiet:true
    )

    on spnSceneUnits changed val do
    (
        if val > 0.0 do
        (
            forestUnitsPerGameMeter = val
            forestSaveMemoryState quiet:true
        )
    )

    on btnUseSystemScale pressed do
    (
        local systemScale = forestSystemUnitsPerMeter()
        forestUnitsPerGameMeter = systemScale
        spnSceneUnits.value = systemScale

        format "Forest Generator: масштаб взят из System Units: 1 м = % units.\n" systemScale
    )

    on btnLoadMask pressed do
    (
        local fileName = getOpenFileName \
            caption:"Выберите маску PNG/TGA" \
            types:"PNG (*.png)|*.png|TGA (*.tga)|*.tga|"

        if fileName != undefined do
        (
            local newBitmap = undefined

            try
            (
                newBitmap = openBitmap fileName
            )
            catch
            (
                newBitmap = undefined
            )

            if newBitmap == undefined then
            (
                forestStudioNotice "Не удалось открыть выбранное изображение." title:"Генератор леса"
            )
            else
            (
                try
                (
                    if forestMaskBitmap != undefined do
                    (
                        close forestMaskBitmap
                    )
                )
                catch()

                forestMaskBitmap = newBitmap
                forestMaskPath = fileName

                lblMaskInfo.text = (filenameFromPath fileName) + " — " + \
                    (forestMaskBitmap.width as string) + " x " + \
                    (forestMaskBitmap.height as string)

                local alphaStats = forestGetMaskAlphaStats forestMaskBitmap sampleCount:48

                if alphaStats[1] then
                (
                    lblAlphaInfo.text = "Alpha: ДА | sampled min=" + \
                        ((alphaStats[2] as integer) as string) + \
                        " max=" + ((alphaStats[3] as integer) as string) + \
                        " avg=" + ((alphaStats[4] as integer) as string)

                    format "Forest Generator: mask Alpha detected. sampled min=% max=% avg=%\n" \
                        alphaStats[2] alphaStats[3] alphaStats[4]

                    if alphaStats[2] >= 254.5 do
                    (
                        forestStudioNotice \
                            "В файле есть Alpha-канал, но во взятых пробах он полностью белый (255).\n\nЕсли вы рисовали чёрную область Alpha, проверьте сохранение файла: для TGA нужен 32-bit, а Alpha должен быть записан в файл. После изменения маски загрузите её заново." \
                            title:"Генератор леса — Alpha"
                    )
                )
                else
                (
                    lblAlphaInfo.text = "Alpha: НЕТ — плотность по Alpha не работает"

                    forestStudioNotice \
                        "3ds Max загрузил эту маску БЕЗ Alpha-канала.\n\nВ таком случае все пиксели считаются полностью непрозрачными, поэтому чёрная полоса в отдельном канале не влияет на посадку.\n\nДля TGA сохраните файл как 32-bit с Alpha. Для PNG убедитесь, что файл действительно RGBA/с прозрачностью. Затем загрузите маску заново." \
                        title:"Генератор леса — Alpha не найден"
                )

                btnEyedropper.enabled = true
                forestSaveMemoryState quiet:true
            )
        )
    )

    on btnEyedropper pressed do
    (
        if forestMaskBitmap == undefined then
        (
            forestStudioNotice "Сначала загрузите маску." title:"Генератор леса"
        )
        else
        (
            local initialColor = color 255 0 0

            if (forestCurrentGroupIndex >= 1) and (forestCurrentGroupIndex <= forestGroupsList.count) do
            (
                initialColor = cpColorPicker.color
            )

            local pickedColor = colorPickerDlg initialColor "Цвет зоны маски" alpha:false

            if pickedColor != undefined do
            (
                if (forestCurrentGroupIndex >= 1) and (forestCurrentGroupIndex <= forestGroupsList.count) then
                (
                    cpColorPicker.color = pickedColor

                    local group = forestGroupsList[forestCurrentGroupIndex]
                    group.color = [pickedColor.r, pickedColor.g, pickedColor.b]

                    forestRefreshGroupsList selectIndex:forestCurrentGroupIndex
                    forestSaveMemoryState quiet:true
                )
                else
                (
                    forestStudioNotice "Создайте и выберите группу, чтобы назначить ей цвет." title:"Генератор леса"
                )
            )
        )
    )

    on btnCreateGroup pressed do
    (
        forestCreateGroup()
        forestSaveMemoryState quiet:true
    )

    on btnDeleteGroup pressed do
    (
        forestDeleteCurrentGroup()
        forestSaveMemoryState quiet:true
    )

    on lbGroups selected index do
    (
        forestLoadGroupToUI index
    )

    on btnApply pressed do
    (
        forestApplyCurrentGroupSettings()
        forestSaveMemoryState quiet:true
    )

    on btnPresetManager pressed do
    (
        try (destroyDialog forestPresetUI) catch()
        createDialog forestPresetUI width:520 height:410
    )

    on btnLibrary pressed do
    (
        try (destroyDialog forestLibraryUI) catch()
        createDialog forestLibraryUI width:1130 height:736
    )

    on btnSDKImport pressed do
    (
        try (destroyDialog forestImportUI) catch()
        createDialog forestImportUI width:520 height:305
    )

    on btnSDKLOD pressed do
    (
        try (destroyDialog forestLodUI) catch()
        createDialog forestLodUI width:520 height:255
    )

    on btnSDKExport pressed do
    (
        try (destroyDialog forestExportUI) catch()
        createDialog forestExportUI width:520 height:335
    )

    on btnGenerate pressed do
    (
        local settingsOK = true

        if spnSceneUnits.value > 0.0 do
        (
            forestUnitsPerGameMeter = spnSceneUnits.value
        )

        if forestCurrentGroupIndex >= 1 do
        (
            settingsOK = forestApplyCurrentGroupSettings()
        )

        if settingsOK do
        (
            settingsOK = forestLibraryPrepareMissingForGroups()
        )

        if settingsOK do
        (
            forestSaveMemoryState quiet:true
            generateForest()
        )
    )

    on forestUI close do
    (
        try
        (
            forestCommitCurrentGroupUIQuiet()
            forestSaveMemoryState quiet:true
        )
        catch()
    )
)

forestLoadPresetManagerSettings()
forestLoadMemoryState quiet:true forceLoad:false
-- Studio backend: classic rollout is defined but not created.
-- Open the UI from Forest_Studio_v0_3.ms.

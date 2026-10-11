/*
    FOREST STUDIO 2.0 / v0.4 WPF Integration (3ds Max 2024)
    UI compiled separately with Build_WPF.cmd. No automatic changes to SDK .object/.thm.
    Actual import, LOD, generation, presets, export come from stable v0.3 backend.
*/

global FS04_WINDOW
global FS04_FOLDER = getFilenamePath (getSourceFileName())
global FS04_UPDATING = false
-- Save the user's accelerator state and restore it on deactivation/close.
global FS04_ACCEL_CAPTURE
global FS04_ACCEL_PREVIOUS
if FS04_ACCEL_CAPTURE == undefined do FS04_ACCEL_CAPTURE = false
if FS04_ACCEL_PREVIOUS == undefined do FS04_ACCEL_PREVIOUS = true

fn fs04CaptureKeyboard shouldCapture =
(
    if shouldCapture then
    (
        if not FS04_ACCEL_CAPTURE do
        (
            FS04_ACCEL_PREVIOUS = enableAccelerators
            enableAccelerators = false
            FS04_ACCEL_CAPTURE = true
        )
    )
    else
    (
        if FS04_ACCEL_CAPTURE do
        (
            enableAccelerators = FS04_ACCEL_PREVIOUS
            FS04_ACCEL_CAPTURE = false
        )
    )
    true
)


fn fs04Message msg = (format "Forest Studio v0.4.6: %\n" msg)
fn fs04Float strValue fallback =
(
    local resultValue = fallback
    try (resultValue = (strValue as float)) catch()
    resultValue
)
fn fs04Int strValue fallback =
(
    local resultValue = fallback
    try (resultValue = (strValue as integer)) catch()
    resultValue
)
fn fs04Status msg =
(
    fs04Message msg
    if FS04_WINDOW != undefined do (try (FS04_WINDOW.SetStatus msg) catch())
)

-- One SDK root: objects = rawdata\objects, textures = gamedata\textures.
fn fs04SdkRootFromObjects objectsPath =
(
    local path = forestTrimTrailingSlash objectsPath
    local suffix = "\\rawdata\\objects"
    if path == "" then return ""
    if (path.count > suffix.count) and ((toLower (substring path (path.count - suffix.count + 1) suffix.count)) == suffix) then
        (substring path 1 (path.count - suffix.count))
    else path
)
fn fs04SdkRoot = (fs04SdkRootFromObjects forestSDKObjectsRoot)
fn fs04ApplySdkRoot value =
(
    local root = forestTrimTrailingSlash value
    if root == "" then return false
    local objectsPath = root + "\\rawdata\\objects"
    local texturesPath = root + "\\gamedata\\textures"
    if not doesDirectoryExist objectsPath then
    (
        FS04_WINDOW.Notify ("Не найдена папка:\n" + objectsPath + "\nВыбери именно корневую папку SDK.") "Forest Studio — SDK"
        return false
    )
    forestSaveSDKObjectsRoot objectsPath
    forestSaveSDKTexturesRoot texturesPath
    if not doesDirectoryExist texturesPath do fs04Status ("Предупреждение: нет папки текстур " + texturesPath)
    forestLibraryDiscoverModels()
    local manifest = forestLibraryWriteDynamicCatalog()
    if manifest != undefined do FS04_WINDOW.LoadAssetCatalog manifest
    FS04_WINDOW.SetSdkRoot root
    fs04Status ((forestLibraryCatalog.count as string) + " моделей найдено в дереве SDK\\rawdata\\objects\\trees")
    true
)
fn fs04Notice msg =
(
    if FS04_WINDOW != undefined then FS04_WINDOW.Notify msg "Forest Studio"
    else messageBox msg title:"Forest Studio"
)
fn fs04Ask msg =
(
    if FS04_WINDOW != undefined then FS04_WINDOW.Confirm msg "Forest Studio"
    else queryBox msg title:"Forest Studio"
)
fn fs04FocusBack = (try (FS04_WINDOW.RestoreStudioFocus()) catch())

fn fs04ProjectRefresh =
(
    if FS04_WINDOW == undefined then return false
    local terrainText = if (forestTerrain != undefined) and (isValidNode forestTerrain) then forestTerrain.name else "Террейн не выбран"
    local maskText = if forestMaskPath != "" then forestMaskPath else "Маска не загружена"
    local infoText = "RGB: цвет группы | Alpha: плотность"
    if forestMaskBitmap != undefined do
    (
        local stats = forestGetMaskAlphaStats forestMaskBitmap sampleCount:24
        infoText = (forestMaskBitmap.width as string) + " x " + (forestMaskBitmap.height as string)
        infoText += if stats[1] then (" | Alpha " + (stats[2] as string) + "..." + (stats[3] as string)) else " | Alpha отсутствует"
    )
    FS04_WINDOW.SetProject terrainText maskText forestUnitsPerGameMeter forestSeed forestUseSubObj (fs04SdkRoot()) forestLastScenePart infoText
    true
)
fn fs04GroupsRefresh =
(
    if FS04_WINDOW == undefined then return false
    FS04_UPDATING = true
    FS04_WINDOW.ClearGroups()
    for i=1 to forestGroupsList.count do
    (
        local g = forestGroupsList[i]
        local rgb = ((g.color.x as integer) as string) + "," + ((g.color.y as integer) as string) + "," + ((g.color.z as integer) as string)
        FS04_WINDOW.AddGroup g.groupName rgb g.densityPerHa g.scaleMin g.scaleMax g.distInside g.tiltStrength g.randomRotY g.alignNormal
        local refs = forestLibraryRefsForGroup g
        for sourceIndex=1 to refs.count do
        (
            local weightValue = 100.0
            if sourceIndex <= g.sourceWeights.count do weightValue = g.sourceWeights[sourceIndex]
            FS04_WINDOW.AddGroupAssetWeighted (i-1) refs[sourceIndex] weightValue
        )
    )
    FS04_WINDOW.EndGroups (forestCurrentGroupIndex - 1)
    FS04_UPDATING = false
    true
)
fn fs04PresetsRefresh =
(
    FS04_WINDOW.ClearPresets()
    for name in (forestPresetNames()) do (FS04_WINDOW.AddPreset name)
)
fn fs04ExportRefresh =
(
    local nodes = forestCollectGeneratedNodes()
    FS04_WINDOW.SetExportState ((nodes.count as string) + " объектов в Forest_* слоях. Сначала проверь ref_name.")
)
fn fs04RefreshAll =
(
    fs04ProjectRefresh()
    fs04GroupsRefresh()
    fs04PresetsRefresh()
    fs04ExportRefresh()
)
fn fs04ProjectSave quiet:false =
(
    local m = fs04Float FS04_WINDOW.ProjectScale forestUnitsPerGameMeter
    if m <= 0.0 then (if not quiet do fs04Notice "Масштаб сцены должен быть больше нуля."; return false)
    forestUnitsPerGameMeter = m
    forestSeed = fs04Int FS04_WINDOW.ProjectSeed forestSeed
    forestUseSubObj = FS04_WINDOW.ProjectSubObject
    if FS04_WINDOW.ProjectSdkRoot != "" do
    (
        local targetRoot = forestTrimTrailingSlash FS04_WINDOW.ProjectSdkRoot
        if (toLower targetRoot) != (toLower (fs04SdkRoot())) do
        (
            if not fs04ApplySdkRoot targetRoot then return false
        )
    )
    if FS04_WINDOW.ProjectPartPath != "" do forestSaveScenePart FS04_WINDOW.ProjectPartPath
    forestSaveMemoryState quiet:true
    true
)
fn fs04GroupCreate =
(
    local i = forestGroupsList.count + 1
    local g = ForestGroup groupName:("Группа " + (i as string)) layerName:"FG_LOD_Sources" usePresetSources:true
    for j=1 to forestGroupsList.count do
    (
        append g.distToOther #(j, 3.0)
        append forestGroupsList[j].distToOther #(i, 3.0)
    )
    append forestGroupsList g
    forestCurrentGroupIndex = i
    forestSaveMemoryState quiet:true
    fs04GroupsRefresh()
)
fn fs04GroupDelete =
(
    local i = forestCurrentGroupIndex
    if (i < 1) or (i > forestGroupsList.count) then return false
    if fs04Ask ("Удалить группу '" + forestGroupsList[i].groupName + "'?") do
    (
        deleteItem forestGroupsList i
        forestRebuildDistancesAfterDelete i
        forestCurrentGroupIndex = if forestGroupsList.count > 0 then 1 else 0
        forestSaveMemoryState quiet:true
        fs04GroupsRefresh()
    )
)
fn fs04GroupSave quiet:false =
(
    local i = forestCurrentGroupIndex
    if (i < 1) or (i > forestGroupsList.count) then return false
    local g = forestGroupsList[i]
    local rgbParts = filterString FS04_WINDOW.GroupRgb ",; "
    if rgbParts.count != 3 then (if not quiet do fs04Notice "RGB должен быть записан как 255,0,0"; return false)
    local lowScale = fs04Float FS04_WINDOW.GroupMin g.scaleMin
    local highScale = fs04Float FS04_WINDOW.GroupMax g.scaleMax
    if (lowScale <= 0) or (lowScale > highScale) then (if not quiet do fs04Notice "Проверь значения масштаба."; return false)
    g.groupName = FS04_WINDOW.GroupName
    g.color = [amin 255 (amax 0 (fs04Float rgbParts[1] 255)), amin 255 (amax 0 (fs04Float rgbParts[2] 0)), amin 255 (amax 0 (fs04Float rgbParts[3] 0))]
    g.densityPerHa = amax 0.0 (fs04Float FS04_WINDOW.GroupDensity g.densityPerHa)
    g.scaleMin = lowScale
    g.scaleMax = highScale
    g.distInside = amax 0.0 (fs04Float FS04_WINDOW.GroupInside g.distInside)
    g.tiltStrength = amin 30.0 (amax 0.0 (fs04Float FS04_WINDOW.GroupTilt g.tiltStrength))
    g.randomRotY = FS04_WINDOW.GroupRotation
    g.alignNormal = FS04_WINDOW.GroupAlign
    forestSaveMemoryState quiet:true
    if not quiet do (fs04GroupsRefresh(); fs04Status "Параметры группы сохранены")
    true
)
-- Build groups from representative RGB colors returned by the WPF palette preview.
-- Do not modify the mask or import any model here.
fn fs04CreateGroupsFromMask rgbList =
(
    local candidates = filterString rgbList ";"
    if candidates.count == 0 then return false
    local created = 0
    local already = 0
    for rgbEntry in candidates do
    (
        local parts = filterString rgbEntry ","
        if parts.count == 3 do
        (
            local r = amin 255 (amax 0 (fs04Int parts[1] 0))
            local g = amin 255 (amax 0 (fs04Int parts[2] 0))
            local b = amin 255 (amax 0 (fs04Int parts[3] 0))
            local exists = false
            for group in forestGroupsList do
            (
                local dr = (group.color.x - r)
                local dg = (group.color.y - g)
                local db = (group.color.z - b)
                if ((dr*dr + dg*dg + db*db) <= 256.0) do exists = true
            )
            if exists then
                already += 1
            else
            (
                local newIndex = forestGroupsList.count + 1
                local groupName = "RGB " + (r as string) + "," + (g as string) + "," + (b as string)
                local newGroup = ForestGroup groupName:groupName layerName:"FG_LOD_Sources" color:[r,g,b] usePresetSources:true
                for j=1 to forestGroupsList.count do
                (
                    append newGroup.distToOther #(j, 3.0)
                    append forestGroupsList[j].distToOther #(newIndex, 3.0)
                )
                append forestGroupsList newGroup
                created += 1
            )
        )
    )
    if created > 0 do
    (
        forestCurrentGroupIndex = forestGroupsList.count
        forestSaveMemoryState quiet:true
        fs04GroupsRefresh()
    )
    fs04Status ((created as string) + " групп создано по маске, " + (already as string) + " совпали с существующими.")
    true
)

-- Deletion is restricted to the explicit user property forest_generated.
-- LOD source objects, terrains, and arbitrary Forest_* layer content are safe.
fn fs04DeleteGenerated =
(
    local candidates = #()
    for n in objects do
    (
        if isValidNode n do
        (
            local tag = ""
            try (tag = (getUserProp n "forest_generated") as string) catch()
            if ((toLower tag) == "true") or (tag == "1") do append candidates n
        )
    )
    if candidates.count == 0 then
    (
        fs04Notice "В сцене нет объектов с меткой forest_generated."
        return false
    )
    if not (fs04Ask ("Удалить " + (candidates.count as string) + " сгенерированных объектов?\nОперацию можно отменить в 3ds Max (Ctrl+Z).")) then return false
    undo "Forest Studio: удалить генерацию" on
    (
        for n in candidates where (isValidNode n) do (try (delete n) catch())
    )
    local failedCount = 0
    for n in candidates where (isValidNode n) do failedCount += 1
    for grp in forestGroupsList do grp.placedPositions = #()
    forestSaveMemoryState quiet:true
    fs04ExportRefresh()
    fs04Status (((candidates.count - failedCount) as string) + " сгенерированных объектов удалено (Undo доступен)")
    if failedCount > 0 do fs04Notice ((failedCount as string) + " объектов не удалось удалить, смотри Listener.")
    true
)

fn fs04PickGroupColor =
(
    local i = forestCurrentGroupIndex
    if (i < 1) or (i > forestGroupsList.count) then
    (
        fs04Notice "Сначала выбери группу."
        return false
    )
    local oldColor = forestGroupsList[i].color
    local initialColor = color (oldColor.x as integer) (oldColor.y as integer) (oldColor.z as integer)
    local pickedColor = colorPickerDlg initialColor "Цвет зоны RGB-маски" alpha:false
    if pickedColor != undefined do
    (
        local rgb = ((pickedColor.r as integer) as string) + "," + \
                    ((pickedColor.g as integer) as string) + "," + \
                    ((pickedColor.b as integer) as string)
        FS04_WINDOW.SetGroupRgb rgb
        -- Save after updating the WPF field, preserving all other edits.
        fs04GroupSave()
    )
    fs04FocusBack() -- MAXScript colorPickerDlg is hosted by Max; restore WPF focus after it closes.
    true
)

fn fs04GroupAdd =
(
    local i = FS04_WINDOW.SelectedLibraryGroup + 1
    local refs = filterString FS04_WINDOW.SelectedAssetRefs "|"
    if (i < 1) or (i > forestGroupsList.count) then (fs04Notice "Сначала создай и выбери группу."; return false)
    if refs.count < 1 then return false
    forestCurrentGroupIndex = i
    local countAdded = forestLibraryAddRefs i refs
    fs04GroupsRefresh()
    fs04Status ((countAdded as string) + " моделей добавлено в группу")
)
fn fs04GroupRemoveAsset =
(
    local i = FS04_WINDOW.SelectedLibraryGroup + 1
    local j = FS04_WINDOW.SelectedMember + 1
    if (i > 0) and (j > 0) do
    (
        forestLibraryDeleteRef i j
        forestCurrentGroupIndex = i
        fs04GroupsRefresh()
    )
)
fn fs04SelectedRefs = (filterString FS04_WINDOW.SelectedAssetRefs "|")
fn fs04RunGenerate =
(
    if not fs04ProjectSave() then return false
    if (forestTerrain == undefined) or (not isValidNode forestTerrain) then (fs04Notice "Не назначен террейн."; return false)
    if forestMaskBitmap == undefined then (fs04Notice "Не загружена маска."; return false)
    if not (fs04Ask "Запустить подготовку LOD и генерацию леса?") then return false
    fs04Status "Подготовка источников..."
    if forestLibraryPrepareMissingForGroups() do
    (
        fs04Status "Генерация леса..."
        generateForest()
        fs04Status "Генерация завершена. Проверь Listener."
        fs04ExportRefresh()
    )
)
fn fs04ExportNodes =
(
    if FS04_WINDOW.ExportSelectedOnly then
        (for n in selection where (isValidNode n) and (superClassOf n == GeometryClass) collect n)
    else forestCollectGeneratedNodes()
)
fn fs04ExportCheck =
(
    fs04ProjectSave()
    local result = forestValidateExportNodes (fs04ExportNodes())
    if result[2].count > 0 do forestPrintIssues result[2]
    local msg = ((result[1].count as string) + " готово | " + (result[2].count as string) + " ошибок")
    FS04_WINDOW.SetExportState msg
    fs04Status msg
)
fn fs04ExportRun =
(
    fs04ProjectSave()
    local dest = FS04_WINDOW.ProjectPartPath
    if not doesFileExist dest then (fs04Notice "Выбери существующий scene_object.part."; return false)
    forestSaveScenePart dest
    local nodes = fs04ExportNodes()
    local valid = forestValidateExportNodes nodes
    if (valid[1].count == 0) or (valid[2].count > 0) then
    (
        forestPrintIssues valid[2]
        fs04Notice "Экспорт отменён: не все объекты имеют правильный ref_name/.object."
        return false
    )
    if fs04Ask ("Записать " + (nodes.count as string) + " объектов в .part? Будет создан backup.") do
    (
        local ok = forestExportNodesToPart nodes dest prefixText:FS04_WINDOW.ExportPrefix
        FS04_WINDOW.SetExportState (if ok then "Экспорт завершён" else "Ошибка экспорта, см. Listener")
        fs04Status (if ok then "SDK экспорт завершён" else "Ошибка экспорта")
    )
)
fn fs04ActionHandler sender args =
(
    if FS04_UPDATING then return false
    local command = args.Command
    try
    (
        case command of
        (
            "TerrainSelection":
            (
                if (selection.count == 1) and forestGeometryFilter selection[1] then
                (forestTerrain = selection[1]; forestSaveMemoryState quiet:true; fs04ProjectRefresh())
                else fs04Notice "Выдели в Max ровно один геометрический объект террейна."
            )
            "MaskBrowse":
            (
                local f = FS04_WINDOW.ChooseFile "Маска леса *_forest.tga" "Forest TGA (*_forest.tga)|*_forest.tga|Все TGA (*.tga)|*.tga" forestMaskPath
                if f != "" do
                (
                    local name = toLower (getFilenameFile f)
                    if ((name.count >= 7) and ((substring name (name.count - 6) 7) == "_forest")) then
                    (
                        if forestRestoreMaskFromPath f then
                        (forestSaveMemoryState quiet:true; fs04ProjectRefresh())
                        else fs04Notice "Не удалось прочитать TGA. Проверь формат файла."
                    )
                    else fs04Notice "Имя рабочей маски должно оканчиваться на _forest.tga"
                )
            )
            "MaskFindByTexture":
            (
                local f = FS04_WINDOW.ChooseFile "Выбрать текстуру террейна (поиск _forest.tga)" "Текстуры (*.dds;*.tga;*.png)|*.dds;*.tga;*.png|Все файлы (*.*)|*.*" (fs04SdkRoot())
                if f != "" do
                (
                    local stem = getFilenameFile f
                    local names = #( (getFilenamePath f) + stem + "_forest.tga", (fs04SdkRoot()) + "\\rawdata\\textures\\" + stem + "_forest.tga", (fs04SdkRoot()) + "\\gamedata\\textures\\" + stem + "_forest.tga" )
                    local found = ""
                    for candidate in names where (found == "") and (doesFileExist candidate) do found = candidate
                    if found != "" then
                    (
                        if forestRestoreMaskFromPath found do (forestSaveMemoryState quiet:true; fs04ProjectRefresh())
                    )
                    else fs04Notice ("Не найдено: " + stem + "_forest.tga\nУкажи путь вручную через кнопку «Открыть *_forest.tga».")
                )
            )
            "BrowseSDK":
            (
                local chosen = FS04_WINDOW.ChooseSdkFolder (fs04SdkRoot())
                if chosen != "" do (if fs04ApplySdkRoot chosen do fs04ProjectRefresh())
            )
            "BrowsePart":
            (
                local p = FS04_WINDOW.ChooseFile "scene_object.part" "X-Ray Scene Part (*.part)|*.part|Все файлы (*.*)|*.*" forestLastScenePart
                if p != "" do (forestSaveScenePart p; fs04ProjectRefresh())
            )
            "ProjectSave": (if fs04ProjectSave() do (fs04ProjectRefresh(); fs04Status "Состояние проекта сохранено"))
            "PresetSave":
            (
                local n = FS04_WINDOW.PresetName
                if (n != "") and ((findString n "[") == undefined) and ((findString n "]") == undefined) do
                (
                    if forestWriteGeneratorState (forestActivePresetFile()) n includeSources:true groupsOnly:true do
                    (forestPresetLastName = n; forestSavePresetManagerSettings(); fs04PresetsRefresh(); fs04Status ("Пресет сохранён: " + n))
                )
            )
            "PresetLoad":
            (
                local n = FS04_WINDOW.SelectedPreset
                if (n != "") and (fs04Ask ("Применить пресет '" + n + "' вместо текущих настроек?")) do
                (
                    if forestReadGeneratorState (forestActivePresetFile()) n restoreSources:true restoreAssets:false quiet:false groupsOnly:true do
                    (fs04RefreshAll(); forestSaveMemoryState quiet:true; fs04Status "Пресет применён")
                )
            )
            "MaskCreateGroups": (fs04CreateGroupsFromMask args.Value)
            "GroupCreate": (fs04GroupCreate())
            "GroupDelete": (fs04GroupDelete())
            "GroupSelected": (forestCurrentGroupIndex = fs04Int args.Value forestCurrentGroupIndex)
            "GroupSave": (fs04GroupSave())
            "GroupAutoSave": (fs04GroupSave quiet:true)
            "MemberWeight":
            (
                local parts = filterString args.Value "|"
                if parts.count == 3 do
                (
                    forestLibrarySetSourceWeight (fs04Int parts[1] 0) (fs04Int parts[2] 0) (fs04Float parts[3] 100.0)
                )
            )
            "ProjectAutoSave":
            (
                local newRoot = forestTrimTrailingSlash FS04_WINDOW.ProjectSdkRoot
                if (newRoot == "") or (doesDirectoryExist (newRoot + "\\rawdata\\objects")) do
                    fs04ProjectSave quiet:true
            )
            "PickGroupColor": (fs04PickGroupColor())
            "GroupAddAssets": (fs04GroupAdd())
            "GroupRemoveAsset": (fs04GroupRemoveAsset())
            "PrepareSelected":
            (
                local refs = fs04SelectedRefs()
                if refs.count > 0 do (local prepared = forestLibraryPrepareRefs refs; fs04Status ((prepared.count as string) + " LOD подготовлено"))
            )
            "PrepareGroup":
            (
                local idx = forestCurrentGroupIndex
                if idx>=1 and idx<=forestGroupsList.count do
                (
                    local prepared = forestLibraryPrepareRefs (forestLibraryRefsForGroup forestGroupsList[idx])
                    fs04Status ((prepared.count as string) + " LOD подготовлено")
                )
            )
            "BuildThumbnails":
            (
                if forestLibraryCreateThumbnails() do
                (FS04_WINDOW.InvalidateThumbnails(); fs04Status "Кэш THM обновлён")
            )
            "ClearThumbnails":
            (
                if fs04Ask "Очистить PNG-кэш миниатюр каталога? Исходные .thm/.object не пострадают." do
                (
                    FS04_WINDOW.InvalidateThumbnails()
                    local result = forestLibraryClearThumbnailCache()
                    FS04_WINDOW.InvalidateThumbnails()
                    fs04Status ((result[1] as string) + " кэш-файлов удалено. Теперь нажми THM → PNG (Flip Y).")
                    if result[2] > 0 do fs04Notice ((result[2] as string) + " файлов не удалось удалить; проверь права доступа.")
                )
            )
            "WindowActivated": (fs04CaptureKeyboard true)
            "WindowDeactivated": (fs04CaptureKeyboard false)
            "Generate": (fs04RunGenerate())
            "DeleteGenerated": (fs04DeleteGenerated())
            "ExportCheck": (fs04ExportCheck())
            "ExportRun": (fs04ExportRun())
            "Closed": (fs04CaptureKeyboard false; try (forestSaveMemoryState quiet:true) catch(); FS04_WINDOW = undefined)
        )
    )
    catch
    (
        local errorString = getCurrentException()
        fs04Message ("ERROR " + command + ": " + errorString)
        fs04Notice ("Команда '" + command + "' завершилась ошибкой:\n" + errorString + "\nПодробности в Listener")
    )
)

/* safe startup */
try (fs04CaptureKeyboard false) catch()
try (if FS04_WINDOW != undefined do FS04_WINDOW.Close()) catch()
FS04_WINDOW = undefined
localBackendPath = FS04_FOLDER + "Forest_Studio_Backend.ms"
localDllPath = FS04_FOLDER + "ForestStudio.Wpf.dll"
if not doesFileExist localBackendPath then
(
    fs04Notice ("Не найден backend: " + localBackendPath)
)
else if not doesFileExist localDllPath then
(
    fs04Notice "Не найдена ForestStudio.Wpf.dll.\nЗапусти Build_WPF.cmd из папки комплекта, затем снова открой этот .ms."
)
else
(
    try
    (
        fileIn localBackendPath
        forestObjectImporterScript = FS04_FOLDER + "xrTools.ObjectImport.ms"
        forestLibraryThumbnailToolPath = FS04_FOLDER + "forest_thm_cache.py"
        dotNet.loadAssembly localDllPath
        FS04_WINDOW = dotNetObject "ForestStudio.UI.StudioWindow"
        dotNet.addEventHandler FS04_WINDOW "ActionRequested" fs04ActionHandler
        -- Auto-migrate previous sdk\rawdata\objects setting to SDK root.
        forestLoadSDKSettings()
        local currentSdkRoot = fs04SdkRoot()
        if currentSdkRoot != "" and doesDirectoryExist (currentSdkRoot + "\\rawdata\\objects") then
            fs04ApplySdkRoot currentSdkRoot
        else
        (
            forestLibraryCatalog = #()
            local catalogFile = forestLibraryWriteDynamicCatalog()
            if catalogFile != undefined do FS04_WINDOW.LoadAssetCatalog catalogFile
        )
        FS04_WINDOW.SetThumbnailDirectory (forestLibraryCacheDirectory())
        fs04RefreshAll()
        FS04_WINDOW.Show()
        fs04Status "WPF v0.4.5 запущен. Движок v0.3 подключён."
    )
    catch
    (
        local msg = getCurrentException()
        format "Forest Studio startup failed: %\n" msg
        fs04CaptureKeyboard false
        fs04Notice ("Ошибка запуска v0.4.5:\n" + msg + "\nСм. MAXScript Listener")
    )
)

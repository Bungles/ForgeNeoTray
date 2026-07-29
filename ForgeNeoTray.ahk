#Requires AutoHotkey v2.0
#SingleInstance Force
try DllCall("SetProcessDpiAwarenessContext", "ptr", -4, "int")
Persistent()
OnError(LogError)

LogError(err, *) {
    logPath := A_ScriptDir "\ForgeNeoTray_error.log"
    FileAppend(A_Now " - " err.Message "`n", logPath)
    TrimLogFile(logPath, 500)
    MsgBox("ForgeNeoTray hit an error:`n" err.Message "`n`nLogged to:`n" logPath)
    return true
}

TrimLogFile(path, maxLines) {
    try {
        content := FileRead(path)
    } catch {
        return
    }
    lines := StrSplit(content, "`n")
    if lines.Length <= maxLines
        return
    startIdx := lines.Length - maxLines + 1
    trimmed := ""
    loop maxLines {
        trimmed .= lines[startIdx + A_Index - 1] "`n"
    }
    try {
        FileDelete(path)
        FileAppend(trimmed, path)
    }
}

; ============ Settings ============
SettingsPath := A_ScriptDir "\ForgeNeoTray_settings.ini"
isFirstRun := !FileExist(SettingsPath)

if isFirstRun {
    if !FileExist(A_ScriptDir "\webui-user.bat") {
        FirstRunSetup()
        return
    }
    IniWrite(A_ScriptDir, SettingsPath, "Settings", "ForgeNeoDir")
    IniWrite("webui-user.bat", SettingsPath, "Settings", "ForgeNeoBat")
    IniWrite("http://127.0.0.1:7860", SettingsPath, "Settings", "ForgeNeoURL")
    IniWrite(0, SettingsPath, "Settings", "HideConsoleOnLaunch")
    IniWrite(0, SettingsPath, "Settings", "StartupDelaySeconds")
    IniWrite("release", SettingsPath, "Settings", "UpdateMode")
    IniWrite(0, SettingsPath, "Settings", "CheckUpdatesOnLaunch")
    IniWrite(0, SettingsPath, "Settings", "EnableExtensionsUpdater")
}

InitRuntimeGlobals()
CheckStartupRegistryOnLaunch()

if isFirstRun
    ShowCenteredNotice("Forge Neo Tray", "Found webui-user.bat — launching Forge Neo now.`n`nRight-click the tray icon anytime to open Settings, including if you ever move this program to a different folder later.", true)
; ===================================

; Reads settings from the .ini into the globals every part of the script relies on,
; and sets up the always-needed runtime state (window detection, tray tracking vars).
; Called both from normal startup and from FirstRunSetup, so clicking "Settings" from
; either first-run notice has everything it needs rather than hitting unassigned globals.
InitRuntimeGlobals() {
    global SettingsPath, ForgeNeoDir, ForgeNeoBat, ForgeNeoURL, HideConsoleOnLaunch, StartupDelaySeconds
    global RunKeyName, RunKeyPath, ForgePID, clickPending, SettingsGuiRef, SuppressCrashNotice, PendingSettingsAlwaysOnTop, SuppressStartupWrite
    global UpdateMode, CheckUpdatesOnLaunch, EnableExtensionsUpdater

    ForgeNeoDir := IniRead(SettingsPath, "Settings", "ForgeNeoDir", A_ScriptDir)
    ForgeNeoBat := IniRead(SettingsPath, "Settings", "ForgeNeoBat", "webui-user.bat")
    ForgeNeoURL := IniRead(SettingsPath, "Settings", "ForgeNeoURL", "http://127.0.0.1:7860")
    HideConsoleOnLaunch := Integer(IniRead(SettingsPath, "Settings", "HideConsoleOnLaunch", "1"))
    StartupDelaySeconds := Integer(IniRead(SettingsPath, "Settings", "StartupDelaySeconds", "0"))
    UpdateMode := IniRead(SettingsPath, "Settings", "UpdateMode", "release")
    CheckUpdatesOnLaunch := Integer(IniRead(SettingsPath, "Settings", "CheckUpdatesOnLaunch", "0"))
    EnableExtensionsUpdater := Integer(IniRead(SettingsPath, "Settings", "EnableExtensionsUpdater", "0"))
    RunKeyName := "ForgeNeoTray"
    RunKeyPath := "HKCU\Software\Microsoft\Windows\CurrentVersion\Run"

    DetectHiddenWindows(true)
    SetTitleMatchMode(2)
    ForgePID := 0
    clickPending := false
    SettingsGuiRef := 0
    SuppressCrashNotice := false
    PendingSettingsAlwaysOnTop := false
    SuppressStartupWrite := false
}

StartForgeAndTray()

; Launches Forge Neo (respecting the startup delay) and sets up the tray icon and
; crash-monitor timer. Called both from normal startup and from FirstRunSetup's
; ContinueClicked, so completing first-run setup doesn't need Reload() at all —
; avoiding the risk of restarting the whole process out from under a Settings
; window someone opened from the "Setup complete" notice.
StartForgeAndTray() {
    global StartupDelaySeconds, CheckUpdatesOnLaunch
    if StartupDelaySeconds > 0
        SetTimer(LaunchForge, -(StartupDelaySeconds * 1000))
    else
        LaunchForge()
    SetTrayIcon()
    SetTimer(CheckForgeStatus, 5000)
    SetTimer(SetTrayIcon, 60000)
    if CheckUpdatesOnLaunch
        SetTimer(CheckUpdatesSilently, -5000)
}

; Runs once per launch, regardless of whether Settings ever gets opened this session —
; catches a startup entry left pointing at a different copy of ForgeNeoTray.exe (e.g.
; from testing multiple install locations) before it goes unnoticed indefinitely.
CheckStartupRegistryOnLaunch() {
    global SuppressStartupWrite
    existingPath := GetStartupRegistryPath()
    if existingPath = "" || existingPath = A_ScriptFullPath
        return
    choice := ShowRepointStartupDialog(existingPath)
    if choice.rewrite
        SetStartupState(true)
    else
        SuppressStartupWrite := true
}

ClearStartupSuppress(*) {
    global SuppressStartupWrite
    SuppressStartupWrite := false
}

TrayClickHandler(*) {
    global clickPending
    if clickPending {
        clickPending := false
        SetTimer(DoSingleClick, 0)
        OpenBrowser()
    } else {
        clickPending := true
        SetTimer(DoSingleClick, -200)
    }
}

DoSingleClick() {
    global clickPending
    clickPending := false
    ToggleConsole()
}

ToggleConsole(*) {
    hwnd := WinExist("ForgeNeoConsole")
    if !hwnd
        return
    if DllCall("IsWindowVisible", "ptr", hwnd)
        WinHide()
    else {
        WinShow()
        WinActivate()
    }
}

CheckForgeStatus() {
    global ForgePID, SuppressCrashNotice
    if (ForgePID && !SuppressCrashNotice && !ProcessExist(ForgePID)) {
        TrayTip("The Forge Neo process appears to have stopped unexpectedly.", "Forge Neo", 2)
        ForgePID := 0
    }
}

SetTrayIcon() {
    A_IconTip := "Forge Neo"
    A_TrayMenu.Delete()
    A_TrayMenu.Add("Show/Hide Console", TrayClickHandler)
    A_TrayMenu.Add("Launch in Browser", OpenBrowser)

    OpenMenu := Menu()
    OpenMenu.Add("Install Folder", OpenInstallFolder)
    AddFolderMenuItem(OpenMenu, "Models", ForgeNeoDir "\models")
    AddFolderMenuItem(OpenMenu, "img2img-images", ForgeNeoDir "\output\img2img-images", false)
    AddFolderMenuItem(OpenMenu, "txt2img-images", ForgeNeoDir "\output\txt2img-images", false)
    A_TrayMenu.Add("Open...", OpenMenu)

    A_TrayMenu.Add()
    A_TrayMenu.Add("Settings", OpenSettingsWindow)
    A_TrayMenu.Add()
    if EnableExtensionsUpdater {
        UpdateMenu := Menu()
        UpdateMenu.Add("SD Forge Neo", CheckForUpdates)

        ExtMenu := Menu()
        ExtMenu.Add("Update All", UpdateAllExtensions)
        ExtMenu.Add()
        for extName in GetGitExtensionFolders()
            ExtMenu.Add(extName, MakeUpdateExtensionCallback(extName))
        UpdateMenu.Add("Extensions", ExtMenu)

        A_TrayMenu.Add("Check for Updates", UpdateMenu)
    } else {
        A_TrayMenu.Add("Update SD Forge Neo", CheckForUpdates)
    }
    A_TrayMenu.Add("Restart Forge Neo", RestartForge)
    A_TrayMenu.Add("Exit", ExitForge)
    A_TrayMenu.Default := "Show/Hide Console"
    A_TrayMenu.ClickCount := 1
}

; ============ Functions ============
LaunchForge() {
    global ForgePID, ForgeNeoDir, ForgeNeoBat, HideConsoleOnLaunch, SuppressCrashNotice
    fullPath := ForgeNeoDir "\" ForgeNeoBat
    if !FileExist(fullPath) {
        TrayTip("Could not find " fullPath ".`nUse Settings to fix the path.", "Forge Neo Tray", 2)
        ForgePID := 0
        return
    }
    cmd := 'cmd.exe /c title ForgeNeoConsole && cd /d "' ForgeNeoDir '" && "' ForgeNeoBat '"'
    winState := HideConsoleOnLaunch ? "Hide" : ""
    Run(cmd, ForgeNeoDir, winState, &ForgePID)
    SuppressCrashNotice := false
}

OpenBrowser(*) {
    Run(ForgeNeoURL)
}

OpenInstallFolder(*) {
    global ForgeNeoDir
    if !FileExist(ForgeNeoDir) {
        ShowCenteredNotice("Forge Neo Tray", "That folder couldn't be found. Use Settings to fix the path.")
        return
    }
    Run(ForgeNeoDir)
}

OpenFolderPath(path) {
    if !FileExist(path) {
        ShowCenteredNotice("Forge Neo Tray", "That folder couldn't be found:`n" path)
        return
    }
    Run(path)
}

; AHK reuses the same loop variable across iterations rather than giving each one its
; own binding, so a callback created directly inside a loop would end up pointing at
; whatever the variable holds after the loop finishes (always the last folder) rather
; than the one it was created for. Routing through a real function call like this one
; gives each callback its own genuinely separate parameter instead.
MakeOpenFolderCallback(path) {
    return (*) => OpenFolderPath(path)
}

; Returns YYYY-MM-DD-named subfolders of parentDir, newest first, or an empty array if
; the folder doesn't exist or has none — used to build the date drill-down submenus.
GetDateSubfolders(parentDir) {
    names := []
    if !FileExist(parentDir)
        return names
    Loop Files, parentDir "\*.*", "D" {
        if RegExMatch(A_LoopFileName, "^\d{4}-\d{2}-\d{2}$")
            names.Push(A_LoopFileName)
    }
    if names.Length = 0
        return names
    joined := ""
    for i, n in names
        joined .= (i = 1 ? "" : "`n") n
    return StrSplit(Sort(joined, "R"), "`n")
}

; Adds a folder entry to the Open... submenu. If the folder has date-named subfolders,
; it becomes its own submenu (an "Open X Folder" entry plus one entry per date);
; otherwise it's just a direct clickable item.
AddFolderMenuItem(parentMenu, label, folderPath, includeOpenEntry := true) {
    dateFolders := GetDateSubfolders(folderPath)
    if dateFolders.Length = 0 {
        parentMenu.Add(label, MakeOpenFolderCallback(folderPath))
        return
    }
    subMenu := Menu()
    if includeOpenEntry {
        subMenu.Add("Open " label " Folder", MakeOpenFolderCallback(folderPath))
        subMenu.Add()
    }
    for d in dateFolders
        subMenu.Add(d, MakeOpenFolderCallback(folderPath "\" d))
    parentMenu.Add(label, subMenu)
}

; Kills the launched cmd.exe process and everything under it (python, etc.) by PID
; rather than by window handle. WinClose-by-PID is unreliable here because on systems
; where Windows Terminal is the default terminal app, the visible console window is
; owned by WindowsTerminal.exe, not by cmd.exe's own PID — so WinExist/WinClose can't
; find it. taskkill /T works directly against the process tree regardless of which
; window (if any) is hosting it.
KillForgeProcess() {
    global ForgePID
    if ForgePID && ProcessExist(ForgePID) {
        try RunWait('taskkill /F /T /PID ' ForgePID, , "Hide")
    }
    ForgePID := 0
}

; Runs a git command in the given working directory and returns its trimmed output.
RunGitCapture(workDir, gitArgs) {
    tmp := A_Temp "\ForgeNeoTray_git_" A_TickCount "_" Random(1000, 9999) ".txt"
    RunWait('cmd.exe /c cd /d "' workDir '" && git ' gitArgs ' > "' tmp '" 2>&1', , "Hide")
    result := FileExist(tmp) ? Trim(FileRead(tmp)) : ""
    try FileDelete(tmp)
    return result
}

DetectGitFailureReason(output) {
    if InStr(output, "Your local changes")
        return "You have local changes that would be overwritten."
    else if RegExMatch(output, "i)could not resolve host|unable to access|Could not read from remote")
        return "Couldn't reach GitHub. Check your internet connection."
    return "See details below for the full output."
}

; Shown only once we already know a specific tagged release is genuinely available and
; safely fast-forwardable from the current commit.
ShowUpdateAvailableDialog(msg) {
    result := {proceed: false}
    Dlg := Gui("-DPIScale", "Update Available")
    Dlg.SetFont("s10")
    Dlg.AddText("xm ym w360", msg)
    CancelBtn := Dlg.AddButton("xm y+20 w110", "Cancel")
    UpdateBtn := Dlg.AddButton("xm+220 yp w140 Default", "Update Now")
    UpdateBtn.OnEvent("Click", (*) => (result.proceed := true, Dlg.Destroy()))
    CancelBtn.OnEvent("Click", (*) => Dlg.Destroy())
    Dlg.OnEvent("Close", (*) => Dlg.Destroy())
    Dlg.Show()
    CenterGuiOnMonitor(Dlg)
    WinWaitClose("ahk_id " Dlg.Hwnd)
    return result
}

; True if ancestorRef is an ancestor of descendantRef — used to check, without changing
; anything, whether fast-forwarding from the current commit to a release tag is possible.
GitIsAncestor(workDir, ancestorRef, descendantRef) {
    exitCode := RunWait('cmd.exe /c cd /d "' workDir '" && git merge-base --is-ancestor ' ancestorRef ' ' descendantRef, , "Hide")
    return exitCode = 0
}

; A result notice with an Expand Details button that reveals the full git output in a
; scrollable box, resizing and re-centering the window rather than showing everything
; up front — the raw output can run to hundreds of lines on a big update.
ShowUpdateResultNotice(summary, fullOutput, offerRestart) {
    expanded := false
    DetailsEdit := 0
    hasDetails := Trim(fullOutput) != ""
    NoticeGui := Gui("-DPIScale", "Update Result")
    NoticeGui.SetFont("s10")
    SummaryText := NoticeGui.AddText("xm ym w360", summary)

    if hasDetails {
        ExpandBtn := NoticeGui.AddButton("xm y+15 w150", "Expand Details")
        ExpandBtn.GetPos(&ebx, &eby, &ebw, &ebh)
        ExpandBtn.OnEvent("Click", ToggleExpand)
    } else {
        SummaryText.GetPos(&ebx, &eby, &ebw, &ebh)
    }

    if offerRestart {
        RestartBtn := NoticeGui.AddButton("xm y" (eby + ebh + 15) " w120", "Restart now")
        RestartBtn.OnEvent("Click", (*) => (NoticeGui.Destroy(), RestartForge()))
        OkBtn := NoticeGui.AddButton("xm+260 yp w100 Default", "OK")
    } else {
        OkBtn := NoticeGui.AddButton("xm+260 y" (eby + ebh + 15) " w100 Default", "OK")
    }
    OkBtn.OnEvent("Click", (*) => NoticeGui.Destroy())
    NoticeGui.OnEvent("Close", (*) => NoticeGui.Destroy())

    ; Individual GuiControl objects have no .Destroy() method (only the whole Gui does),
    ; so the details box is created once, lazily, and then just toggled visible/hidden.
    ; The empty-space bug wasn't really about create-vs-hide — it's that AHK's window
    ; auto-sizing accounts for every control's bounds regardless of visibility. Explicitly
    ; overriding the window height each time (based on where the buttons actually end up)
    ; sidesteps that entirely rather than fighting the auto-size behavior.
    ToggleExpand(*) {
        expanded := !expanded
        if !IsObject(DetailsEdit)
            DetailsEdit := NoticeGui.AddEdit("xm y" (eby + ebh + 10) " w360 h200 -Theme ReadOnly VScroll Multi", fullOutput)
        DetailsEdit.Visible := expanded
        ExpandBtn.Text := expanded ? "Collapse Details" : "Expand Details"
        if expanded {
            DetailsEdit.GetPos(&dx, &dy, &dw, &dh)
            newY := dy + dh + 15
        } else {
            newY := eby + ebh + 15
        }
        if offerRestart {
            RestartBtn.Move(, newY)
            OkBtn.Move(, newY)
        } else {
            OkBtn.Move(, newY)
        }
        OkBtn.GetPos(&okx, &oky, &okw, &okh)
        NoticeGui.Show("h" (oky + okh + 20))
        CenterGuiOnMonitor(NoticeGui)
    }

    NoticeGui.Show()
    CenterGuiOnMonitor(NoticeGui)
    WinWaitClose("ahk_id " NoticeGui.Hwnd)
}

; Performs the read-only fetch + comparison for whichever UpdateMode is configured,
; without ever pulling anything. Shared by the interactive tray menu check and the
; silent launch-time check, so both use identical logic rather than two copies that
; could drift apart. Returns {ok, available, message, fetchOutput, target, displayTarget}.
;
; HEAD mode fetches the specific branch by name (found via a live remote query) and
; compares against FETCH_HEAD, rather than trusting a local origin/<branch> tracking
; ref — those can be stale or entirely missing for single-branch clones if the remote's
; default branch was ever renamed, since the local fetch config stays pinned to the old
; name even though origin/HEAD correctly reports the new one.
CheckUpdateStatus() {
    global ForgeNeoDir, UpdateMode
    result := {ok: false, available: false, message: "", fetchOutput: "", target: "", displayTarget: ""}

    if UpdateMode = "head" {
        symrefOutput := RunGitCapture(ForgeNeoDir, "ls-remote --symref origin HEAD")
        if !RegExMatch(symrefOutput, "refs/heads/(\S+)\s+HEAD", &m) {
            result.message := "Update failed: Couldn't determine the default branch from the remote."
            result.fetchOutput := symrefOutput
            return result
        }
        branchName := m[1]

        fetchOutFile := A_Temp "\ForgeNeoTray_gitfetch.txt"
        try FileDelete(fetchOutFile)
        fetchExit := RunWait('cmd.exe /c cd /d "' ForgeNeoDir '" && git fetch origin ' branchName ' > "' fetchOutFile '" 2>&1', , "Hide")
        fetchOutput := FileExist(fetchOutFile) ? FileRead(fetchOutFile) : ""
        try FileDelete(fetchOutFile)
        result.fetchOutput := fetchOutput
        if fetchExit != 0 {
            result.message := "Update failed: " DetectGitFailureReason(fetchOutput)
            return result
        }
        result.ok := true

        currentHash := RunGitCapture(ForgeNeoDir, "rev-parse --short HEAD")
        targetHash := RunGitCapture(ForgeNeoDir, "rev-parse --short FETCH_HEAD")
        if targetHash = "" {
            result.message := "Couldn't resolve the fetched commit."
            return result
        }
        if currentHash = targetHash {
            result.message := "Already running the latest commit on " branchName "."
            return result
        }
        if !GitIsAncestor(ForgeNeoDir, "HEAD", "FETCH_HEAD") {
            result.message := "Can't safely update from your current state — your local history has diverged from origin/" branchName "."
            return result
        }
        countOutput := RunGitCapture(ForgeNeoDir, "rev-list HEAD..FETCH_HEAD --count")
        behindCount := IsInteger(countOutput) ? Integer(countOutput) : 0
        plural := behindCount = 1 ? "" : "s"
        result.available := true
        result.target := "FETCH_HEAD"
        result.displayTarget := targetHash
        result.message := behindCount " new commit" plural " available on " branchName ".`n`nCurrent: " currentHash "`nLatest: " targetHash
    } else {
        fetchOutFile := A_Temp "\ForgeNeoTray_gitfetch.txt"
        try FileDelete(fetchOutFile)
        fetchExit := RunWait('cmd.exe /c cd /d "' ForgeNeoDir '" && git fetch --tags > "' fetchOutFile '" 2>&1', , "Hide")
        fetchOutput := FileExist(fetchOutFile) ? FileRead(fetchOutFile) : ""
        try FileDelete(fetchOutFile)
        result.fetchOutput := fetchOutput
        if fetchExit != 0 {
            result.message := "Update failed: " DetectGitFailureReason(fetchOutput)
            return result
        }
        result.ok := true

        tagList := RunGitCapture(ForgeNeoDir, "tag --sort=-v:refname")
        latestTag := ""
        for t in StrSplit(tagList, "`n") {
            t := Trim(t)
            if RegExMatch(t, "^\d+(\.\d+)*$") {
                latestTag := t
                break
            }
        }
        if latestTag = "" {
            result.message := "No tagged releases were found in this repository."
            return result
        }
        currentHash := RunGitCapture(ForgeNeoDir, "rev-parse --short HEAD")
        tagHash := RunGitCapture(ForgeNeoDir, "rev-parse --short " latestTag)

        if currentHash = tagHash {
            result.message := "Already running the latest release (" latestTag ")."
            return result
        }
        if !GitIsAncestor(ForgeNeoDir, "HEAD", latestTag) {
            if GitIsAncestor(ForgeNeoDir, latestTag, "HEAD")
                result.message := "You're already ahead of the latest tagged release (" latestTag ") — you're on newer commits from the neo branch."
            else
                result.message := "Can't safely update to release " latestTag " from your current state — your local history has diverged from it."
            return result
        }
        result.available := true
        result.target := latestTag
        result.displayTarget := latestTag
        result.message := "Release " latestTag " is available.`n`nCurrent commit: " currentHash
    }
    return result
}

; Performs the actual fast-forward and reports the result. Only ever reached after an
; explicit user confirmation — never called from the silent launch-time check.
ApplyUpdate(target, displayTarget) {
    global ForgeNeoDir
    outFile := A_Temp "\ForgeNeoTray_gitpull.txt"
    try FileDelete(outFile)
    exitCode := RunWait('cmd.exe /c cd /d "' ForgeNeoDir '" && git merge --ff-only "' target '" > "' outFile '" 2>&1', , "Hide")
    output := FileExist(outFile) ? FileRead(outFile) : "(no output captured)"
    try FileDelete(outFile)

    if exitCode != 0 {
        summaryText := "Update failed: " DetectGitFailureReason(output)
    } else {
        summaryText := "Successfully updated to " displayTarget "."
    }
    ShowUpdateResultNotice(summaryText, output, exitCode = 0)
}

CheckForUpdates(*) {
    global ForgeNeoDir

    if !FileExist(ForgeNeoDir "\.git") {
        ShowCenteredNotice("Forge Neo Tray", "This doesn't look like a git installation (no .git folder found in your Forge Neo directory), so it can't be updated this way.")
        return
    }

    busy := ShowBusyNotice("Checking for updates...")
    status := CheckUpdateStatus()
    busy.Destroy()
    if !status.ok || !status.available {
        ShowUpdateResultNotice(status.message, status.fetchOutput, false)
        return
    }

    choice := ShowUpdateAvailableDialog(status.message)
    if !choice.proceed
        return

    ApplyUpdate(status.target, status.displayTarget)
}

; ============ Extension updates ============
; Extensions rarely use tagged releases the way the core repo does, so these always
; track the branch HEAD directly rather than respecting the release/HEAD Settings
; toggle — release-tag checking would just return "no tags found" for most of them.

GetGitExtensionFolders() {
    global ForgeNeoDir
    result := []
    extDir := ForgeNeoDir "\extensions"
    if !FileExist(extDir)
        return result
    Loop Files, extDir "\*", "D" {
        if FileExist(A_LoopFileFullPath "\.git")
            result.Push(A_LoopFileName)
    }
    return result
}

CheckExtensionUpdateStatus(extDir) {
    result := {ok: false, available: false, message: "", fetchOutput: "", target: "", displayTarget: ""}

    symrefOutput := RunGitCapture(extDir, "ls-remote --symref origin HEAD")
    if !RegExMatch(symrefOutput, "refs/heads/(\S+)\s+HEAD", &m) {
        result.message := "Update failed: Couldn't determine the default branch from the remote."
        result.fetchOutput := symrefOutput
        return result
    }
    branchName := m[1]

    ; Fetch this specific branch explicitly, bypassing whatever restricted fetch
    ; refspec a single-branch clone might have configured — common for extensions,
    ; and can leave the local origin/<branch> tracking ref stale or entirely absent
    ; if the remote's default branch was ever renamed after the clone was made.
    fetchOutFile := A_Temp "\ForgeNeoTray_extfetch_" A_TickCount "_" Random(1000, 9999) ".txt"
    try FileDelete(fetchOutFile)
    fetchExit := RunWait('cmd.exe /c cd /d "' extDir '" && git fetch origin ' branchName ' > "' fetchOutFile '" 2>&1', , "Hide")
    fetchOutput := FileExist(fetchOutFile) ? FileRead(fetchOutFile) : ""
    try FileDelete(fetchOutFile)
    result.fetchOutput := fetchOutput

    if fetchExit != 0 {
        result.message := "Update failed: " DetectGitFailureReason(fetchOutput)
        return result
    }
    result.ok := true

    currentHash := RunGitCapture(extDir, "rev-parse --short HEAD")
    targetHash := RunGitCapture(extDir, "rev-parse --short FETCH_HEAD")

    if targetHash = "" {
        result.message := "Couldn't resolve the fetched commit for this extension."
        return result
    }
    if currentHash = targetHash {
        result.message := "Already up to date."
        return result
    }
    if !GitIsAncestor(extDir, "HEAD", "FETCH_HEAD") {
        result.message := "Local history has diverged — can't safely update."
        return result
    }
    result.available := true
    result.target := "FETCH_HEAD"
    result.displayTarget := targetHash
    result.message := "Update available (" targetHash ")."
    return result
}

ApplyExtensionUpdate(extDir, target, displayTarget) {
    outFile := A_Temp "\ForgeNeoTray_extpull_" A_TickCount "_" Random(1000, 9999) ".txt"
    try FileDelete(outFile)
    exitCode := RunWait('cmd.exe /c cd /d "' extDir '" && git merge --ff-only "' target '" > "' outFile '" 2>&1', , "Hide")
    output := FileExist(outFile) ? FileRead(outFile) : ""
    try FileDelete(outFile)
    if exitCode != 0
        return {summary: "Update failed: " DetectGitFailureReason(output), output: output, updated: false}
    return {summary: "Updated to " displayTarget ".", output: output, updated: true}
}

; Same closure-capture issue as the date-folder menu items — a factory function gives
; each tray item its own genuinely separate extension name rather than all sharing
; whatever the loop variable holds after it finishes.
MakeUpdateExtensionCallback(extName) {
    return (*) => UpdateSingleExtension(extName)
}

UpdateSingleExtension(extName) {
    global ForgeNeoDir
    extDir := ForgeNeoDir "\extensions\" extName
    busy := ShowBusyNotice("Checking " extName " for updates...")
    status := CheckExtensionUpdateStatus(extDir)
    busy.Destroy()
    if !status.ok || !status.available {
        ShowUpdateResultNotice(extName ": " status.message, status.fetchOutput, false)
        return
    }
    choice := ShowUpdateAvailableDialog(extName "`n`n" status.message)
    if !choice.proceed
        return
    result := ApplyExtensionUpdate(extDir, status.target, status.displayTarget)
    ShowUpdateResultNotice(extName ": " result.summary, result.output, result.updated)
}

; A checkbox list, one row per extension — extensions with an update available are
; checkable (pre-ticked); ones already current or that failed the check are shown as
; plain greyed-out status text instead, since there's nothing actionable for them.
ShowExtensionUpdateChecklist(items) {
    result := {proceed: false, selected: []}
    Dlg := Gui("-DPIScale", "Update Extensions")
    Dlg.SetFont("s10")
    Dlg.AddText("xm ym w400", "Select which extensions to update:")
    y := 40
    rows := []
    for it in items {
        if it.status.ok && it.status.available {
            c := Dlg.AddCheckbox("xm y" y " w400 -Theme Checked", it.name " — update available (" it.status.displayTarget ")")
            rows.Push({ctrl: c, item: it})
        } else {
            statusText := it.status.ok ? "up to date" : "check failed"
            Dlg.AddText("xm y" y " w400 cGray", it.name " — " statusText)
            rows.Push({ctrl: 0, item: it})
        }
        y += 26
    }
    UpdateBtn := Dlg.AddButton("xm y" (y + 15) " w150", "Update Selected")
    CancelBtn := Dlg.AddButton("x+20 yp w100 Default", "Cancel")
    UpdateBtn.OnEvent("Click", ConfirmClick)
    CancelBtn.OnEvent("Click", (*) => Dlg.Destroy())
    Dlg.OnEvent("Close", (*) => Dlg.Destroy())

    ConfirmClick(*) {
        result.proceed := true
        for row in rows {
            if IsObject(row.ctrl) && row.ctrl.Value
                result.selected.Push(row.item)
        }
        Dlg.Destroy()
    }

    Dlg.Show()
    CenterGuiOnMonitor(Dlg)
    WinWaitClose("ahk_id " Dlg.Hwnd)
    return result
}

; A lightweight, non-blocking "please wait" window — caller must Destroy() it manually
; once the actual work finishes. The brief Sleep lets it actually paint before whatever
; blocking work comes next, since we're about to run several sequential RunWait calls.
ShowBusyNotice(text) {
    BusyGui := Gui("-DPIScale", "Please Wait")
    BusyGui.SetFont("s10")
    BusyGui.AddText("xm ym w300", text)
    BusyGui.Show()
    CenterGuiOnMonitor(BusyGui)
    Sleep(50)
    return BusyGui
}

UpdateAllExtensions(*) {
    global ForgeNeoDir
    extFolders := GetGitExtensionFolders()
    if extFolders.Length = 0 {
        ShowCenteredNotice("Forge Neo Tray", "No git-based extensions were found in your extensions folder.")
        return
    }

    busy := ShowBusyNotice("Checking extensions for updates...")
    items := []
    for name in extFolders {
        dir := ForgeNeoDir "\extensions\" name
        items.Push({name: name, dir: dir, status: CheckExtensionUpdateStatus(dir)})
    }
    busy.Destroy()

    anyAvailable := false
    anyFailed := false
    for it in items {
        if it.status.ok && it.status.available
            anyAvailable := true
        if !it.status.ok
            anyFailed := true
    }
    if !anyAvailable && !anyFailed {
        ShowCenteredNotice("Forge Neo Tray", "All extensions are already up to date.")
        return
    }

    choice := ShowExtensionUpdateChecklist(items)
    if !choice.proceed || choice.selected.Length = 0
        return

    resultLines := []
    for sel in choice.selected {
        r := ApplyExtensionUpdate(sel.dir, sel.status.target, sel.status.displayTarget)
        resultLines.Push(sel.name ": " r.summary)
    }
    combined := ""
    for i, line in resultLines
        combined .= (i = 1 ? "" : "`n") line
    ShowUpdateResultNotice("Updated " choice.selected.Length " extension(s). Restart Forge Neo for the changes to take effect.", combined, true)
}

; Runs in the background shortly after launch (if enabled in Settings) and only ever
; shows a tray notification — never a dialog, never pulls anything automatically.
CheckUpdatesSilently() {
    global ForgeNeoDir
    if !FileExist(ForgeNeoDir "\.git")
        return
    status := CheckUpdateStatus()
    if status.ok && status.available
        TrayTip("An update is available (" status.displayTarget "). Use 'Check for Updates' in the tray menu to install it.", "Forge Neo Tray", 1)
}

RestartForge(*) {
    global SuppressCrashNotice
    SuppressCrashNotice := true
    KillForgeProcess()
    LaunchForge()
}

ExitForge(*) {
    global SuppressCrashNotice
    SuppressCrashNotice := true
    KillForgeProcess()
    ExitApp()
}

; Reads the current Run-key value, stripping any surrounding quotes, so it can be
; compared against A_ScriptFullPath (which is never quoted) regardless of whether the
; stored value was written by this version or an older unquoted one. Returns "" if no
; entry exists at all.
GetStartupRegistryPath() {
    global RunKeyName, RunKeyPath
    try {
        val := RegRead(RunKeyPath, RunKeyName)
        return Trim(val, '"')
    } catch {
        return ""
    }
}

SetStartupState(enable) {
    global RunKeyName, RunKeyPath
    if enable {
        try {
            ; Quoted, matching how Windows itself writes Run-key paths — an unquoted
            ; path with a space in it (e.g. "Program Files") would otherwise get
            ; misread as the start of command-line arguments.
            RegWrite('"' A_ScriptFullPath '"', "REG_SZ", RunKeyPath, RunKeyName)
        } catch {
            MsgBox("Couldn't update the Windows startup setting. This may be restricted by system policy.", "Forge Neo Tray", "Icon!")
        }
    } else {
        try RegDelete(RunKeyPath, RunKeyName)
    }
}

; Shown when a startup entry exists but points at a different ForgeNeoTray.exe than
; this one — asks before silently taking it over.
ShowRepointStartupDialog(oldPath) {
    result := {rewrite: false}
    Dlg := Gui("-DPIScale", "Start with Windows")
    Dlg.SetFont("s10")
    Dlg.AddText("xm ym w380", "Start with Windows is already enabled for a different ForgeNeoTray.exe:`n`n" oldPath "`n`nPoint Windows startup to this copy instead?")
    NoBtn := Dlg.AddButton("xm y+20 w110", "No")
    YesBtn := Dlg.AddButton("xm+250 yp w130 Default", "Use This Copy")
    YesBtn.OnEvent("Click", (*) => (result.rewrite := true, Dlg.Destroy()))
    NoBtn.OnEvent("Click", (*) => Dlg.Destroy())
    Dlg.OnEvent("Close", (*) => Dlg.Destroy())
    Dlg.Show()
    CenterGuiOnMonitor(Dlg)
    WinWaitClose("ahk_id " Dlg.Hwnd)
    return result
}

; ============ Window positioning ============
; Breaks a long description into multiple lines (ToolTip doesn't auto-wrap) by
; inserting `n at the nearest space once a line would exceed maxLen characters.
WrapTooltipText(text, maxLen) {
    words := StrSplit(text, " ")
    lines := []
    current := ""
    for w in words {
        candidate := current = "" ? w : current " " w
        if (StrLen(candidate) > maxLen && current != "") {
            lines.Push(current)
            current := w
        } else {
            current := candidate
        }
    }
    if current != ""
        lines.Push(current)
    result := ""
    for i, l in lines
        result .= (i = 1 ? "" : "`n") l
    return result
}

GetMonitorAtMouse() {
    CoordMode("Mouse", "Screen")
    MouseGetPos(&mx, &my)
    count := MonitorGetCount()
    loop count {
        MonitorGet(A_Index, &L, &T, &R, &B)
        if (mx >= L && mx < R && my >= T && my < B)
            return A_Index
    }
    return MonitorGetPrimary()
}

CenterGuiOnMonitor(guiObj) {
    try {
        monIdx := GetMonitorAtMouse()
        MonitorGetWorkArea(monIdx, &L, &T, &R, &B)
        guiObj.GetPos(&gx, &gy, &gw, &gh)
        newX := L + ((R - L) - gw) // 2
        newY := T + ((B - T) - gh) // 2
        newX := Max(L, Min(newX, R - gw))
        newY := Max(T, Min(newY, B - gh))
        guiObj.Move(newX, newY)
    }
}

; A plain MsgBox() has no owner window to center against this early in the script
; (before any Gui exists), so it falls back to an arbitrary default position. This
; builds a minimal dialog using the same centering logic as everything else instead.
ShowCenteredNotice(title, message, offerSettings := false, offerRestart := false) {
    NoticeGui := Gui("-DPIScale", title)
    NoticeGui.SetFont("s10")
    NoticeGui.AddText("xm ym w360", message)
    if offerSettings {
        SettingsBtn := NoticeGui.AddButton("xm y+20 w100", "Settings")
        SettingsBtn.OnEvent("Click", OpenSettingsFromNotice)
        OkBtn := NoticeGui.AddButton("x+160 yp w100 Default", "OK")
    } else if offerRestart {
        RestartBtn := NoticeGui.AddButton("xm y+20 w120", "Restart now")
        RestartBtn.OnEvent("Click", (*) => (NoticeGui.Destroy(), RestartForge()))
        OkBtn := NoticeGui.AddButton("xm+260 yp w100 Default", "OK")
    } else {
        OkBtn := NoticeGui.AddButton("xm+260 y+20 w100 Default", "OK")
    }
    OkBtn.OnEvent("Click", (*) => NoticeGui.Destroy())
    NoticeGui.OnEvent("Close", (*) => NoticeGui.Destroy())
    NoticeGui.Show()
    CenterGuiOnMonitor(NoticeGui)
    WinWaitClose("ahk_id " NoticeGui.Hwnd)

    OpenSettingsFromNotice(*) {
        global PendingSettingsAlwaysOnTop
        NoticeGui.Destroy()
        PendingSettingsAlwaysOnTop := true
        OpenSettingsWindow()
    }
}

; ============ Settings window ============
OpenSettingsWindow(*) {
    global ForgeNeoDir, ForgeNeoBat, ForgeNeoURL, SettingsPath, SettingsGuiRef, HideConsoleOnLaunch, StartupDelaySeconds, PendingSettingsAlwaysOnTop, UpdateMode, CheckUpdatesOnLaunch, EnableExtensionsUpdater

    if IsObject(SettingsGuiRef) {
        WinActivate("ahk_id " SettingsGuiRef.Hwnd)
        return
    }

    keepOnTop := PendingSettingsAlwaysOnTop
    PendingSettingsAlwaysOnTop := false

    SettingsGui := Gui("-DPIScale", "Forge Neo Tray - Settings")
    SettingsGuiRef := SettingsGui
    SettingsGui.SetFont("s10")
    HoverTips := Map()

    SettingsGui.AddText("xm ym", "Path to webui-user.bat:")
    BatEdit := SettingsGui.AddEdit("xm w470 vBatEdit -Theme", ForgeNeoDir "\" ForgeNeoBat)
    BrowseBtn := SettingsGui.AddButton("x+10 w95 yp-2", "Browse...")
    BrowseBtn.OnEvent("Click", BrowseAndRefreshArgs)
    HoverTips[BatEdit.Hwnd] := "Full path to your webui-user.bat file. Requires a restart to take effect."
    HoverTips[BrowseBtn.Hwnd] := "Browse for your webui-user.bat file. Requires a restart to take effect."

    SettingsGui.AddText("xm y+15", "Forge Neo URL:")
    UrlEdit := SettingsGui.AddEdit("xm w575 vUrlEdit -Theme", ForgeNeoURL)
    HoverTips[UrlEdit.Hwnd] := "The address Forge Neo's WebUI listens on. Only change this if you've customised the port. Requires a restart to take effect."

    StartupCheck := SettingsGui.AddCheckbox("xm y+15 vStartupCheck", "Start with Windows")
    StartupCheck.Value := (GetStartupRegistryPath() = A_ScriptFullPath)
    StartupCheck.OnEvent("Click", ClearStartupSuppress)
    HoverTips[StartupCheck.Hwnd] := "Launches ForgeNeoTray automatically when Windows starts. Takes effect on your next Windows sign-in, not immediately."

    HideConsoleCheck := SettingsGui.AddCheckbox("x+30 yp vHideConsoleCheck", "Hide console window on launch")
    HideConsoleCheck.Value := HideConsoleOnLaunch
    HoverTips[HideConsoleCheck.Hwnd] := "Hides the console window on launch. Requires a restart to take effect."

    SettingsGui.AddText("xm y+15", "Startup delay (seconds):")
    DelayEdit := SettingsGui.AddEdit("x+10 w60 vDelayEdit Number yp-2 -Theme", StartupDelaySeconds)
    HoverTips[DelayEdit.Hwnd] := "Seconds to wait before the very first launch after Windows starts. Only applies at startup, not to Restart Forge Neo."

    CheckUpdatesCheck := SettingsGui.AddCheckbox("xm y+10 vCheckUpdatesCheck", "Check for SD Forge Neo updates on launch")
    CheckUpdatesCheck.Value := CheckUpdatesOnLaunch
    HoverTips[CheckUpdatesCheck.Hwnd] := "Silently checks for an SD Forge Neo update a few seconds after each launch and shows a tray notification if one's found. Never installs anything automatically. You'll need to fully exit and relaunch ForgeNeoTray for this to take effect."

    SettingsGui.AddText("xm y+15", "Update SD Forge Neo from:")
    UpdateModeDDL := SettingsGui.AddDropDownList("x+10 w330 vUpdateModeDDL -Theme", ["Latest stable release", "Latest commits — may include WIP/bugs"])
    UpdateModeDDL.Value := (UpdateMode = "head") ? 2 : 1
    HoverTips[UpdateModeDDL.Hwnd] := "Latest stable release only checks tagged versions. Latest commits tracks the branch directly for faster access to new features, though it may include unfinished work or unfixed bugs between releases. Applies immediately, no restart needed."

    ExtUpdaterCheck := SettingsGui.AddCheckbox("xm y+8 vExtUpdaterCheck", "Enable extensions updater in tray menu (untested)")
    ExtUpdaterCheck.Value := EnableExtensionsUpdater
    HoverTips[ExtUpdaterCheck.Hwnd] := "When enabled, 'Check for Updates' in the tray becomes a submenu with SD Forge Neo and Extensions options. Applies immediately, no restart needed."

    OriginalArgsStr := ReadCommandLineArgs(ForgeNeoDir "\" ForgeNeoBat)
    ArgDefsList := GetArgDefs()
    ParsedArgs := ParseArgsIntoDefs(OriginalArgsStr, ArgDefsList)

    HeaderCtrl := SettingsGui.AddText("xm y+18", "Command-line Arguments:")
    HeaderCtrl.GetPos(&hx, &hy, &hw, &hh)
    gridX := hx
    gridY := hy + hh + 6
    rowH := 26
    colW := 300

    ArgCheckCtrls := []
    ArgValueCtrls := []
    MedVramChk := 0
    LowVramChk := 0
    ApiChk := 0
    CorsChk := 0
    CorsValEdit := 0
    totalRows := Ceil(ArgDefsList.Length / 2)
    for i, def in ArgDefsList {
        col := (i - 1) // totalRows
        row := Mod(i - 1, totalRows)
        cx := gridX + col * colW
        cy := gridY + row * rowH
        chkWidth := 220
        displayLabel := def[1]
        if def[1] = "--reserve-vram"
            chkWidth := 165
        else if def[1] = "--cors-allow-origins"
            chkWidth := 205
        else if (def[1] = "--cuda-malloc" || def[1] = "--cuda-stream") {
            chkWidth := 270
            displayLabel := def[1] " (Nvidia GPU)"
        }
        chk := SettingsGui.AddCheckbox("x" cx " y" cy " w" chkWidth, displayLabel)
        chk.Value := ParsedArgs.checked[i]
        ArgCheckCtrls.Push(chk)
        HoverTips[chk.Hwnd] := def[4] " Requires a restart to take effect."
        if def[1] = "--medvram"
            MedVramChk := chk
        else if def[1] = "--lowvram"
            LowVramChk := chk
        else if def[1] = "--api"
            ApiChk := chk
        else if def[1] = "--cors-allow-origins"
            CorsChk := chk
        if def[2] {
            valEdit := SettingsGui.AddEdit("x+0 yp-3 w70 -Theme", ParsedArgs.values[i])
            ArgValueCtrls.Push(valEdit)
            HoverTips[valEdit.Hwnd] := def[4] " Requires a restart to take effect."
            if def[1] = "--cors-allow-origins"
                CorsValEdit := valEdit
        } else {
            ArgValueCtrls.Push(0)
        }
    }

    LastChk := ArgCheckCtrls[ArgCheckCtrls.Length]
    LastChk.GetPos(&lx, &ly, &lw, &lh)

    ; --medvram and --lowvram are mutually exclusive — grey out the other once one is
    ; ticked, unless both were already set that way in the .bat (rare/edited by hand),
    ; in which case leave both enabled so the user can resolve it themselves rather
    ; than getting locked out of fixing it via the greyed-out checkboxes.
    if !(MedVramChk.Value && LowVramChk.Value) {
        LowVramChk.Enabled := !MedVramChk.Value
        MedVramChk.Enabled := !LowVramChk.Value
    }
    MedVramChk.OnEvent("Click", (*) => LowVramChk.Enabled := !MedVramChk.Value)
    LowVramChk.OnEvent("Click", (*) => MedVramChk.Enabled := !LowVramChk.Value)

    ; --cors-allow-origins only does anything with --api enabled — grey it out
    ; until then, and untick it too since a ticked-but-inert flag would otherwise
    ; still get written to the .bat on save.
    UpdateCorsEnabled(*) {
        if !ApiChk.Value
            CorsChk.Value := false
        CorsChk.Enabled := ApiChk.Value
        CorsValEdit.Enabled := ApiChk.Value
    }
    ApiChk.OnEvent("Click", UpdateCorsEnabled)
    UpdateCorsEnabled()

    SettingsGui.AddText("x" gridX " y" (ly + lh + 12), "Additional arguments:")
    LeftoverEdit := SettingsGui.AddEdit("x" gridX " y+5 w575 vLeftoverArgs -Theme", ParsedArgs.leftover)
    HoverTips[LeftoverEdit.Hwnd] := "Any command-line arguments not covered by the checkboxes above, kept as-is. Requires a restart to take effect."

    ; Re-parses the newly selected .bat and updates every checkbox/value box/interlock to
    ; match it, rather than leaving the grid showing whichever file was open beforehand —
    ; useful if you're switching between multiple Forge Neo installs' .bat files.
    BrowseAndRefreshArgs(*) {
        selected := BrowseForBat(BatEdit)
        if !selected
            return

        OriginalArgsStr := ReadCommandLineArgs(selected)
        newParsed := ParseArgsIntoDefs(OriginalArgsStr, ArgDefsList)
        for i, def in ArgDefsList {
            ArgCheckCtrls[i].Value := newParsed.checked[i]
            if def[2]
                ArgValueCtrls[i].Value := newParsed.values[i]
        }
        LeftoverEdit.Value := newParsed.leftover

        if (MedVramChk.Value && LowVramChk.Value) {
            MedVramChk.Enabled := true
            LowVramChk.Enabled := true
        } else {
            LowVramChk.Enabled := !MedVramChk.Value
            MedVramChk.Enabled := !LowVramChk.Value
        }
        UpdateCorsEnabled()
    }

    CancelBtn := SettingsGui.AddButton("xm y+20 w110", "Cancel")
    SaveRestartBtn := SettingsGui.AddButton("xm+205 yp w160", "Save && Restart")
    SaveBtn := SettingsGui.AddButton("xm+445 yp w130 Default", "Save")

    CancelBtn.OnEvent("Click", (*) => CloseSettings())
    SaveRestartBtn.OnEvent("Click", (*) => SaveClicked(true))
    SaveBtn.OnEvent("Click", (*) => SaveClicked(false))
    SettingsGui.OnEvent("Close", (*) => CloseSettings())

    SetTimer(CheckHoverTip, 150)

    CheckHoverTip() {
        static lastHwnd := 0
        static hoverStart := 0
        static shown := false
        CoordMode("Mouse", "Screen")
        CoordMode("ToolTip", "Screen")
        MouseGetPos(&mx, &my, &winUnderMouse, &ctrlHwnd, 2)
        valid := (winUnderMouse = SettingsGui.Hwnd) && HoverTips.Has(ctrlHwnd)

        if !valid {
            if shown
                ToolTip()
            lastHwnd := 0
            shown := false
            return
        }

        if (ctrlHwnd != lastHwnd) {
            ; Moved to a different control — clear anything shown and restart the delay
            ; before showing a tooltip for this new one, rather than switching instantly.
            if shown
                ToolTip()
            lastHwnd := ctrlHwnd
            hoverStart := A_TickCount
            shown := false
            return
        }

        if (!shown && (A_TickCount - hoverStart) >= 600) {
            ToolTip(WrapTooltipText(HoverTips[ctrlHwnd], 50), mx + 16, my + 16)
            shown := true
        }
    }

    CloseSettings() {
        global SettingsGuiRef
        SetTimer(CheckHoverTip, 0)
        ToolTip()
        SettingsGui.Destroy()
        SettingsGuiRef := 0
    }

    SaveClicked(restart) {
        global ForgeNeoDir, ForgeNeoBat, ForgeNeoURL, SettingsPath, HideConsoleOnLaunch, StartupDelaySeconds, UpdateMode, CheckUpdatesOnLaunch, EnableExtensionsUpdater
        saved := SettingsGui.Submit(false)
        fullBatPath := saved.BatEdit
        newUrl := saved.UrlEdit
        newHideConsole := saved.HideConsoleCheck
        newDelay := saved.DelayEdit != "" ? Integer(saved.DelayEdit) : 0
        newUpdateMode := (saved.UpdateModeDDL = 2) ? "head" : "release"
        newCheckUpdates := saved.CheckUpdatesCheck
        newExtUpdater := saved.ExtUpdaterCheck

        if !FileExist(fullBatPath) {
            MsgBox("That .bat file couldn't be found. Please check the path and try again.", "Forge Neo Tray", "Icon!")
            return
        }

        oldFullPath := ForgeNeoDir "\" ForgeNeoBat
        oldUrl := ForgeNeoURL
        oldHideConsole := HideConsoleOnLaunch

        checkedVals := []
        valueVals := []
        for i, def in ArgDefsList {
            checkedVals.Push(ArgCheckCtrls[i].Value)
            valueVals.Push(def[2] ? ArgValueCtrls[i].Value : "")
        }
        newArgsStr := BuildArgsString(ArgDefsList, checkedVals, valueVals, saved.LeftoverArgs)
        argsWriteOk := WriteCommandLineArgs(fullBatPath, newArgsStr)
        argsChanged := (Trim(newArgsStr) != Trim(OriginalArgsStr))

        SplitPath(fullBatPath, &fileName, &dirPath)
        ForgeNeoDir := dirPath
        ForgeNeoBat := fileName
        ForgeNeoURL := newUrl
        HideConsoleOnLaunch := newHideConsole
        StartupDelaySeconds := newDelay
        UpdateMode := newUpdateMode
        CheckUpdatesOnLaunch := newCheckUpdates
        EnableExtensionsUpdater := newExtUpdater
        if !SuppressStartupWrite
            SetStartupState(saved.StartupCheck)

        IniWrite(ForgeNeoDir, SettingsPath, "Settings", "ForgeNeoDir")
        IniWrite(ForgeNeoBat, SettingsPath, "Settings", "ForgeNeoBat")
        IniWrite(ForgeNeoURL, SettingsPath, "Settings", "ForgeNeoURL")
        IniWrite(HideConsoleOnLaunch, SettingsPath, "Settings", "HideConsoleOnLaunch")
        IniWrite(StartupDelaySeconds, SettingsPath, "Settings", "StartupDelaySeconds")
        IniWrite(UpdateMode, SettingsPath, "Settings", "UpdateMode")
        IniWrite(CheckUpdatesOnLaunch, SettingsPath, "Settings", "CheckUpdatesOnLaunch")
        IniWrite(EnableExtensionsUpdater, SettingsPath, "Settings", "EnableExtensionsUpdater")

        SetTrayIcon()
        CloseSettings()

        if !argsWriteOk
            ShowCenteredNotice("Forge Neo Tray", "Couldn't find a COMMANDLINE_ARGS line in webui-user.bat, so the argument checkboxes weren't saved. Everything else was saved normally.")


        if restart {
            RestartForge()
        } else if (fullBatPath != oldFullPath || newUrl != oldUrl || newHideConsole != oldHideConsole || argsChanged) {
            ShowCenteredNotice("Forge Neo Tray", "Settings saved. Use 'Restart Forge Neo' for the changes to take effect.", false, true)
        }
    }

    SettingsGui.Show()
    CenterGuiOnMonitor(SettingsGui)
    if keepOnTop
        WinSetAlwaysOnTop(1, "ahk_id " SettingsGui.Hwnd)

    ; The first control in a Gui window gets focus automatically on Show(), and Windows
    ; auto-selects an Edit control's full text the first time it receives focus this way.
    ; Explicitly move the caret to the end instead, with nothing selected.
    caretPos := StrLen(BatEdit.Value)
    SendMessage(0x00B1, caretPos, caretPos, BatEdit)
}

BrowseForBat(editCtrl) {
    selected := FileSelect(1, editCtrl.Value, "Select webui-user.bat", "Batch Files (*.bat)")
    if selected
        editCtrl.Value := selected
    return selected
}

; ============ webui-user.bat COMMANDLINE_ARGS editing ============
ReadCommandLineArgs(batPath) {
    try content := FileRead(batPath)
    catch {
        return ""
    }
    for line in StrSplit(content, "`n", "`r") {
        if RegExMatch(line, "i)^\s*set\s+COMMANDLINE_ARGS\s*=\s*(.*)$", &m)
            return Trim(m[1])
    }
    return ""
}

WriteCommandLineArgs(batPath, newArgs) {
    try content := FileRead(batPath)
    catch {
        return false
    }

    lines := StrSplit(content, "`n")
    found := false
    for i, line in lines {
        hasCR := SubStr(line, -1) = "`r"
        bareLine := hasCR ? SubStr(line, 1, StrLen(line) - 1) : line
        if RegExMatch(bareLine, "i)^\s*set\s+COMMANDLINE_ARGS\s*=.*$") {
            lines[i] := "set COMMANDLINE_ARGS=" newArgs (hasCR ? "`r" : "")
            found := true
            break
        }
    }

    if !found {
        if newArgs = ""
            return true
        newContent := "set COMMANDLINE_ARGS=" newArgs "`r`n" content
    } else {
        newContent := ""
        for i, line in lines
            newContent .= (i = 1 ? "" : "`n") line
    }

    try FileCopy(batPath, batPath ".bak", true)
    try {
        FileDelete(batPath)
        FileAppend(newContent, batPath)
        return true
    } catch {
        return false
    }
}

; Known COMMANDLINE_ARGS flags shown as checkboxes. Format: [flag, hasValue, defaultValue]
GetArgDefs() {
    return [
        ["--reserve-vram", true, "2", "Reserves N GB of VRAM as a safety margin, preventing Windows/other apps from causing out-of-memory errors."],
        ["--medvram", false, "", "Reduces VRAM use by splitting the model across GPU/CPU, at some cost to speed. For GPUs with limited VRAM."],
        ["--lowvram", false, "", "Aggressively reduces VRAM use for very limited GPUs, at a significant cost to speed."],
        ["--cuda-malloc", false, "", "Enables PyTorch's built-in CUDA memory allocator, which can reduce memory fragmentation and improve speed."],
        ["--cuda-stream", false, "", "Enables asynchronous CUDA operations to overlap computation and data transfer, often improving speed."],
        ["--pin-shared-memory", false, "", "Uses pinned (page-locked) memory for faster CPU-GPU data transfers."],
        ["--nunchaku", false, "", "Enables support for Nunchaku-quantised (INT4) models for faster inference with lower VRAM use."],
        ["--cors-allow-origins", true, "*", "Allows web pages from the specified origin(s) to access the API. Use * to allow any origin."],
        ["--api", false, "", "Enables the REST API, needed for external tools (browser extensions, scripts) to control Forge Neo."],
        ["--listen", false, "", "Makes the WebUI accessible from other devices on your network, not just this PC."],
        ["--xformers", false, "", "Enables the xFormers memory-efficient attention implementation, often reducing VRAM use and improving speed."],
        ["--autolaunch", false, "", "Automatically opens your default browser to the WebUI once it finishes starting."],
        ["--skip-torch-cuda-test", false, "", "Skips the startup check that verifies CUDA is working. Useful if the check itself is failing incorrectly."],
        ["--administrator", false, "", "Relaunches Forge Neo with administrator privileges. Sometimes needed for symlink-based model sharing."]
    ]
}

; Pulls known flags (and their values) out of the raw args string; whatever's left over
; (anything not in GetArgDefs) is returned separately so custom/uncommon args aren't lost.
ParseArgsIntoDefs(argsStr, defs) {
    remaining := " " argsStr " "
    checked := []
    values := []
    for def in defs {
        flag := def[1]
        if def[2] {
            q := Chr(34)
            if RegExMatch(remaining, "i)(^|\s)" flag "\s+(" q "[^" q "]*" q "|\S+)", &m) {
                values.Push(Trim(m[2], '"'))
                checked.Push(true)
                remaining := StrReplace(remaining, m[0], " ")
            } else {
                values.Push(def[3])
                checked.Push(false)
            }
        } else {
            values.Push("")
            if RegExMatch(remaining, "i)(^|\s)" flag "(\s|$)", &m) {
                checked.Push(true)
                remaining := StrReplace(remaining, m[0], " ")
            } else {
                checked.Push(false)
            }
        }
    }
    leftover := Trim(RegExReplace(remaining, "\s+", " "))
    return {checked: checked, values: values, leftover: leftover}
}

BuildArgsString(defs, checkedArr, valuesArr, leftover) {
    argsStr := ""
    for i, def in defs {
        if checkedArr[i] {
            if def[2] {
                val := valuesArr[i] != "" ? valuesArr[i] : def[3]
                argsStr .= (argsStr = "" ? "" : " ") def[1] " " val
            } else {
                argsStr .= (argsStr = "" ? "" : " ") def[1]
            }
        }
    }
    if Trim(leftover) != ""
        argsStr .= (argsStr = "" ? "" : " ") Trim(leftover)
    return argsStr
}

; ============ First-run setup ============
; Shown only when no settings file exists yet AND webui-user.bat isn't next to the exe —
; e.g. the exe was placed on the Desktop or in its own folder rather than alongside Forge Neo.
FirstRunSetup() {
    global SettingsPath

    SetupGui := Gui("-DPIScale", "Forge Neo Tray - First-Time Setup")
    SetupGui.SetFont("s10")
    SetupGui.AddText("xm ym w380", "webui-user.bat wasn't found next to this program. Locate it below to continue:")
    BatEdit := SetupGui.AddEdit("xm y+10 w275 vBatEdit -Theme", "")
    SetupGui.AddButton("x+10 w95 yp-2", "Browse...").OnEvent("Click", (*) => BrowseForBat(BatEdit))

    SetupGui.AddText("xm y+15", "Forge Neo URL:")
    SetupGui.AddEdit("xm w380 vUrlEdit -Theme", "http://127.0.0.1:7860")

    ExitBtn := SetupGui.AddButton("xm y+20 w100", "Exit")
    ContinueBtn := SetupGui.AddButton("xm+270 yp w110 Default", "Continue")

    ExitBtn.OnEvent("Click", (*) => ExitApp())
    ContinueBtn.OnEvent("Click", ContinueClicked)
    SetupGui.OnEvent("Close", (*) => ExitApp())

    ContinueClicked(*) {
        global SettingsPath, SettingsGuiRef
        saved := SetupGui.Submit(false)
        fullBatPath := saved.BatEdit
        newUrl := saved.UrlEdit

        if !FileExist(fullBatPath) {
            MsgBox("That .bat file couldn't be found. Please check the path and try again.", "Forge Neo Tray", "Icon!")
            return
        }

        SplitPath(fullBatPath, &fileName, &dirPath)
        IniWrite(dirPath, SettingsPath, "Settings", "ForgeNeoDir")
        IniWrite(fileName, SettingsPath, "Settings", "ForgeNeoBat")
        IniWrite(newUrl, SettingsPath, "Settings", "ForgeNeoURL")
        IniWrite(0, SettingsPath, "Settings", "HideConsoleOnLaunch")
        IniWrite(0, SettingsPath, "Settings", "StartupDelaySeconds")
        IniWrite("release", SettingsPath, "Settings", "UpdateMode")
        IniWrite(0, SettingsPath, "Settings", "CheckUpdatesOnLaunch")
        IniWrite(0, SettingsPath, "Settings", "EnableExtensionsUpdater")

        InitRuntimeGlobals()
        CheckStartupRegistryOnLaunch()
        SetupGui.Destroy()

        ShowCenteredNotice("Forge Neo Tray", "Setup complete — launching Forge Neo now.`n`nRight-click the tray icon anytime to open Settings, including if you ever move this program to a different folder later.", true)

        StartForgeAndTray()
    }

    SetupGui.Show()
    CenterGuiOnMonitor(SetupGui)
}

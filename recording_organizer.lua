-- OBS Recording Organizer
-- Automatically organizes recordings by captured window/application name

obs = obslua

-- Global variables
recordings_base_folder = ""
selected_source_name = ""
strict_ascii = false
executable_append_format = ""
recording_segments = {}  -- Track all segments from current recording session
recording_base_path = ""  -- Base path to monitor for new segments

-- ============================================================================
-- OBS Script Callbacks
-- ============================================================================

function script_description()
    return [[<h2>Recording Organizer</h2>
<p><b>Version:</b> 1.3.0</p>
<p>Automatically organizes finished recordings into subdirectories based on the captured window or application name.</p>
<ul>
    <li>Runs automatically after each recording finishes</li>
    <li>Creates subdirectories named after the captured window/app</li>
    <li>Moves recordings into the appropriate subdirectory</li>
    <li>Select specific capture source or use auto-detect</li>
    <li>Smart name cleaning (removes UnrealWindow:, -Win64-Shipping, .exe, .app, etc.)</li>
    <li>Auto-tracks and moves split recordings together (real-time monitoring)</li>
    <li>Cross-platform support: Windows, Linux, and macOS</li>
</ul>
<p><b>Author:</b> Strychnine | <a href="https://github.com/rabbitcannon">GitHub</a> | <a href="https://raccooncult.com">RaccoonCult.com</a></p>
<p><b>Note:</b> Ensure your recording output path is set in OBS Settings.</p>]]
end

function script_properties()
    local props = obs.obs_properties_create()
    
    -- Add folder path property
    obs.obs_properties_add_path(
        props,
        "base_folder",
        "Base Recordings Folder",
        obs.OBS_PATH_DIRECTORY,
        nil,
        nil
    )
    
    -- Add informational text for folder path
    obs.obs_properties_add_text(
        props,
        "info_text",
        "Info: Leave empty to use OBS default recording path",
        obs.OBS_TEXT_INFO
    )
    
    -- Add dropdown for capture source selection
    local source_list = obs.obs_properties_add_list(
        props,
        "selected_source",
        "Capture Source for Folder Naming",
        obs.OBS_COMBO_TYPE_LIST,
        obs.OBS_COMBO_FORMAT_STRING
    )
    
    -- Add "Auto-detect" option (default)
    obs.obs_property_list_add_string(source_list, "Auto-detect (first found)", "")
    
    -- Populate with available capture sources
    populate_source_list(source_list)
    
    -- Add informational text for source selection
    obs.obs_properties_add_text(
        props,
        "source_info",
        "Select which Window/Game Capture source to use for naming folders. Auto-detect uses the first capture source found.",
        obs.OBS_TEXT_INFO
    )

    -- Add dropdown for stripping non-ASCII characters from folder names
    local ascii_mode = obs.obs_properties_add_list(
        props,
        "strict_ascii",
        "Use ASCII-only folder names",
        obs.OBS_COMBO_TYPE_LIST,
        obs.OBS_COMBO_FORMAT_INT
    )
    obs.obs_property_list_add_int(ascii_mode, "Off", 0)
    obs.obs_property_list_add_int(ascii_mode, "On", 1)

    -- Add informational text for ASCII-only setting
    obs.obs_properties_add_text(
        props,
        "strict_ascii_info",
        "If enabled, strips accented and special characters (e.g. TM, R, C, e-acute) from folder names. Useful on Windows where these can be an issue, or for cross-platform portability.",
        obs.OBS_TEXT_INFO
    )

    -- Add dropdown for appending the executable name to the folder
    local exe_format = obs.obs_properties_add_list(
        props,
        "executable_append_format",
        "Append executable name to folder",
        obs.OBS_COMBO_TYPE_LIST,
        obs.OBS_COMBO_FORMAT_STRING
    )
    obs.obs_property_list_add_string(exe_format, "Off", "")
    obs.obs_property_list_add_string(exe_format, " (name)", " (%s)")
    obs.obs_property_list_add_string(exe_format, "_name", "_%s")
    obs.obs_property_list_add_string(exe_format, " - name", " - %s")

    -- Disable the dropdown on non-Windows platforms - executable name extraction
    -- is only meaningful for Windows Window/Game Capture sources
    local is_windows = package.config:sub(1,1) == "\\"
    if not is_windows then
        obs.obs_property_set_enabled(exe_format, false)
    end

    -- Add informational text for the executable-append dropdown
    local exe_info_text
    if is_windows then
        exe_info_text = "Appends the source's executable name (e.g. 'bf6' from 'bf6.exe') to the folder name. Only fires when the OBS source provides one; silently does nothing for sources that don't."
    else
        exe_info_text = "(Only available on Windows.) OBS doesn't expose an equivalent executable name for capture sources on this platform."
    end
    obs.obs_properties_add_text(
        props,
        "executable_append_info",
        exe_info_text,
        obs.OBS_TEXT_INFO
    )

    return props
end

function script_update(settings)
    -- Get the base folder from settings
    recordings_base_folder = obs.obs_data_get_string(settings, "base_folder")

    -- Get the selected capture source
    selected_source_name = obs.obs_data_get_string(settings, "selected_source")

    -- Get the sanitization options
    strict_ascii = obs.obs_data_get_int(settings, "strict_ascii") == 1
    executable_append_format = obs.obs_data_get_string(settings, "executable_append_format")

    obs.script_log(obs.LOG_INFO, string.format(
        "Settings updated - Base folder: '%s', Selected source: '%s', Strict ASCII: %s, Append format: '%s'",
        recordings_base_folder, selected_source_name, tostring(strict_ascii), executable_append_format
    ))
end

function script_load(settings)
    -- Connect to the recording stopped event
    obs.obs_frontend_add_event_callback(on_event)
    obs.script_log(obs.LOG_INFO, "Recording Organizer: Script loaded successfully")
end

function script_unload()
    -- Remove timer if active
    if segment_check_timer then
        obs.timer_remove(check_for_new_segments)
    end
    obs.script_log(obs.LOG_INFO, "Recording Organizer: Script unloaded")
end

-- ============================================================================
-- Event Handlers
-- ============================================================================

function check_for_new_segments()
    -- Get current recording path
    local current_path = obs.obs_frontend_get_last_recording()
    
    if current_path and current_path ~= "" then
        -- Check if this is a new segment we haven't seen
        local already_tracked = false
        for _, path in ipairs(recording_segments) do
            if path == current_path then
                already_tracked = true
                break
            end
        end
        
        if not already_tracked then
            table.insert(recording_segments, current_path)
            obs.script_log(obs.LOG_INFO, "Recording Organizer: Detected new segment: " .. current_path)
        end
    end
end

function on_event(event)
    if event == obs.OBS_FRONTEND_EVENT_RECORDING_STARTING then
        -- Clear segment tracking when a new recording starts
        recording_segments = {}
        recording_base_path = ""
        obs.script_log(obs.LOG_INFO, "Recording Organizer: Recording starting, tracking segments...")
        
        -- Start monitoring for new segments every 2 seconds
        obs.timer_add(check_for_new_segments, 2000)
        
    elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_STOPPED then
        -- Stop monitoring for segments
        obs.timer_remove(check_for_new_segments)
        
        obs.script_log(obs.LOG_INFO, "Recording Organizer: Recording stopped, processing...")
        
        -- Get the last recording file path
        local recording_path = obs.obs_frontend_get_last_recording()
        
        if recording_path and recording_path ~= "" then
            -- Add the last segment if not already tracked
            local already_tracked = false
            for _, path in ipairs(recording_segments) do
                if path == recording_path then
                    already_tracked = true
                    break
                end
            end
            
            if not already_tracked then
                table.insert(recording_segments, recording_path)
            end
            
            obs.script_log(obs.LOG_INFO, string.format("Recording Organizer: Found %d segment(s) to organize", #recording_segments))
            
            -- Organize all segments
            organize_recording_segments()
        else
            obs.script_log(obs.LOG_WARNING, "Recording Organizer: Could not retrieve recording path")
        end
        
    elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_PAUSED then
        obs.script_log(obs.LOG_INFO, "Recording Organizer: Recording paused")
        
    elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_UNPAUSED then
        obs.script_log(obs.LOG_INFO, "Recording Organizer: Recording resumed")
    end
end

-- ============================================================================
-- Core Functionality
-- ============================================================================

function populate_source_list(source_list_property)
    -- Get all sources
    local sources = obs.obs_enum_sources()
    
    if sources then
        for _, source in ipairs(sources) do
            local source_id = obs.obs_source_get_id(source)
            
            -- Only add window capture and game capture sources
            if source_id == "window_capture" or source_id == "game_capture" or source_id == "xcomposite_input" or source_id == "screen_capture" then
                local source_name = obs.obs_source_get_name(source)
                local source_type
                
                if source_id == "window_capture" then
                    source_type = "Window Capture"
                elseif source_id == "game_capture" then
                    source_type = "Game Capture"
                elseif source_id == "screen_capture" then
                    source_type = "macOS Screen Capture"
                else
                    source_type = "XComposite"
                end
                
                -- Add to dropdown with descriptive name
                local display_name = string.format("%s (%s)", source_name, source_type)
                obs.obs_property_list_add_string(source_list_property, display_name, source_name)
            end
        end
        
        obs.source_list_release(sources)
    end
end

function get_active_window_name()
    -- Get the current scene
    local scene_source = obs.obs_frontend_get_current_scene()
    
    if not scene_source then
        obs.script_log(obs.LOG_WARNING, "Recording Organizer: No current scene found")
        return "Unknown"
    end
    
    local scene_name = obs.obs_source_get_name(scene_source)
    obs.script_log(obs.LOG_INFO, "Recording Organizer: Current scene: '" .. scene_name .. "'")
    
    -- Get the scene as an obs_scene_t
    local scene = obs.obs_scene_from_source(scene_source)
    
    if not scene then
        obs.script_log(obs.LOG_WARNING, "Recording Organizer: Could not get scene object")
        obs.obs_source_release(scene_source)
        return "Unknown"
    end
    
    local window_name = nil
    local exe_name = nil

    -- Try to find window capture or game capture sources
    -- If user selected a specific source, use that; otherwise auto-detect
    if selected_source_name and selected_source_name ~= "" then
        obs.script_log(obs.LOG_INFO, "Recording Organizer: Using selected source: " .. selected_source_name)
        window_name, exe_name = find_specific_capture_source(scene, selected_source_name)
    else
        obs.script_log(obs.LOG_INFO, "Recording Organizer: Auto-detecting capture source")
        window_name, exe_name = find_capture_source_name(scene)
    end

    -- Release the scene source
    obs.obs_source_release(scene_source)

    if window_name and window_name ~= "" then
        obs.script_log(obs.LOG_INFO, "Recording Organizer: Raw window name before sanitization: '" .. window_name .. "'")
        -- Clean the name to be folder-safe
        local sanitized = sanitize_folder_name(window_name)

        -- Optionally append the executable name (Windows captures only)
        if executable_append_format and executable_append_format ~= "" and exe_name and exe_name ~= "" then
            local exe_clean = clean_exe(exe_name)
            if exe_clean ~= "" then
                local appended = sanitized .. string.format(executable_append_format, exe_clean)
                obs.script_log(obs.LOG_INFO, "Recording Organizer: Appended executable name: '" .. appended .. "'")
                return appended
            end
        end

        return sanitized
    end

    obs.script_log(obs.LOG_WARNING, "Recording Organizer: No window name found, returning Unknown")
    return "Unknown"
end

function find_specific_capture_source(scene, source_name)
    local window_name = nil
    local exe_name = nil

    local function enum_item(scene, item)
        local source = obs.obs_sceneitem_get_source(item)

        if not source then
            return true -- Continue iteration
        end

        local current_source_name = obs.obs_source_get_name(source)

        if current_source_name == source_name then
            local source_id = obs.obs_source_get_id(source)

            if source_id == "window_capture" or source_id == "game_capture" or source_id == "xcomposite_input" or source_id == "screen_capture" then
                local settings = obs.obs_source_get_settings(source)
                window_name, exe_name = extract_window_info_from_settings(source_id, settings, source)
                obs.obs_data_release(settings)

                if window_name then
                    return false -- Stop iteration
                end
            end
        end

        return true -- Continue iteration
    end

    obs.obs_scene_enum_items(scene, enum_item)

    return window_name, exe_name
end

function find_capture_source_name(scene)
    local window_name = nil
    local exe_name = nil
    local found_sources = 0

    obs.script_log(obs.LOG_INFO, "Recording Organizer: Enumerating ALL sources globally...")

    -- Get all sources in OBS (not just scene items)
    local sources = obs.obs_enum_sources()

    if not sources then
        obs.script_log(obs.LOG_ERROR, "Recording Organizer: Failed to enumerate sources!")
        return nil, nil
    end

    obs.script_log(obs.LOG_INFO, "Recording Organizer: Total sources available: " .. #sources)

    for i, source in ipairs(sources) do
        local source_id = obs.obs_source_get_id(source)
        local source_name = obs.obs_source_get_name(source)

        obs.script_log(obs.LOG_INFO, string.format("Recording Organizer: Source #%d: '%s' (type: %s)", i, source_name, source_id))

        if source_id == "window_capture" or source_id == "game_capture" or source_id == "xcomposite_input" or source_id == "screen_capture" then
            found_sources = found_sources + 1
            obs.script_log(obs.LOG_INFO, "Recording Organizer: Found capture source! Extracting window info...")

            local settings = obs.obs_source_get_settings(source)
            window_name, exe_name = extract_window_info_from_settings(source_id, settings, source)
            obs.obs_data_release(settings)

            if window_name then
                obs.script_log(obs.LOG_INFO, "Recording Organizer: SUCCESS! Found window name: '" .. window_name .. "'")
                obs.source_list_release(sources)
                return window_name, exe_name
            end
        end
    end

    obs.source_list_release(sources)

    obs.script_log(obs.LOG_INFO, "Recording Organizer: Enumeration complete. Capture sources found: " .. found_sources)

    if found_sources == 0 then
        obs.script_log(obs.LOG_WARNING, "Recording Organizer: No Window/Game Capture sources found at all!")
    end

    return window_name, exe_name
end

function extract_window_info_from_settings(source_id, settings, source)
    local window_title = nil
    local exe_name = nil

    if source_id == "window_capture" then
        -- Windows: window property format is "[executable.exe]: Window Title"
        -- macOS: window property format is "Window Title" or "Application - Window Title"
        local window_str = obs.obs_data_get_string(settings, "window")
        obs.script_log(obs.LOG_INFO, "Recording Organizer: Window Capture - raw string: '" .. tostring(window_str) .. "'")

        if window_str and window_str ~= "" then
            window_title = extract_window_title(window_str)
            exe_name = extract_executable_name(window_str, source_id)
            if not window_title or window_title == "" then
                obs.script_log(obs.LOG_WARNING, "Recording Organizer: Failed to extract title from window string")
            end
        else
            obs.script_log(obs.LOG_WARNING, "Recording Organizer: Window Capture has empty window string")
            -- Try using the source name as fallback
            local source_name = obs.obs_source_get_name(source)
            if source_name and source_name ~= "Window Capture" then
                window_title = source_name
                obs.script_log(obs.LOG_INFO, "Recording Organizer: Using source name as fallback: '" .. window_title .. "'")
            end
        end

    elseif source_id == "game_capture" then
        -- Game capture: always try to get window string regardless of mode
        local mode = obs.obs_data_get_int(settings, "mode")
        obs.script_log(obs.LOG_INFO, "Recording Organizer: Game Capture - mode: " .. tostring(mode))

        -- Always try to get the window string (even in mode 0, it might be stored)
        local window_str = obs.obs_data_get_string(settings, "window")
        obs.script_log(obs.LOG_INFO, "Recording Organizer: Game Capture - raw window string: '" .. tostring(window_str) .. "'")

        if window_str and window_str ~= "" then
            window_title = extract_window_title(window_str)
            exe_name = extract_executable_name(window_str, source_id)
            if window_title and window_title ~= "" then
                obs.script_log(obs.LOG_INFO, "Recording Organizer: Successfully extracted from window string!")
            end
        else
            obs.script_log(obs.LOG_WARNING, "Recording Organizer: Game Capture has empty window string (mode: " .. mode .. ")")
        end

        -- Fallback to source name ONLY if we got nothing
        if not window_title or window_title == "" then
            local source_name = obs.obs_source_get_name(source)
            -- Only use source name if it's been customized (not default "Game Capture")
            if source_name and source_name ~= "Game Capture" and source_name ~= "Elgato 4K X Capture" then
                window_title = source_name
                obs.script_log(obs.LOG_INFO, "Recording Organizer: Using customized source name as fallback: '" .. window_title .. "'")
            else
                obs.script_log(obs.LOG_WARNING, "Recording Organizer: No window info available and source name is default/device name")
            end
        end

    elseif source_id == "xcomposite_input" then
        -- Linux: capture_window property
        local window_str = obs.obs_data_get_string(settings, "capture_window")
        obs.script_log(obs.LOG_INFO, "Recording Organizer: XComposite - raw string: '" .. tostring(window_str) .. "'")
        
        if window_str and window_str ~= "" then
            window_title = extract_window_title(window_str)
        else
            obs.script_log(obs.LOG_WARNING, "Recording Organizer: XComposite has empty window string")
        end
        
    elseif source_id == "screen_capture" then
        -- macOS Screen Capture: application property contains bundle ID
        local capture_type = obs.obs_data_get_int(settings, "type")
        obs.script_log(obs.LOG_INFO, "Recording Organizer: macOS Screen Capture - type: " .. tostring(capture_type))
        
        -- Type: 0 = Display, 1 = Window, 2 = Application
        if capture_type == 2 then
            -- Application capture
            local app_bundle = obs.obs_data_get_string(settings, "application")
            obs.script_log(obs.LOG_INFO, "Recording Organizer: macOS Screen Capture - bundle ID: '" .. tostring(app_bundle) .. "'")
            
            if app_bundle and app_bundle ~= "" then
                -- Extract app name from bundle ID (e.g., "com.google.Chrome" -> "Chrome")
                window_title = extract_app_name_from_bundle(app_bundle)
            end
        elseif capture_type == 1 then
            -- Window capture - try to get window info
            local window_id = obs.obs_data_get_int(settings, "window")
            obs.script_log(obs.LOG_INFO, "Recording Organizer: macOS Screen Capture - window ID: " .. tostring(window_id))
            
            -- For window capture, use the source name if it's been customized
            local source_name = obs.obs_source_get_name(source)
            if source_name and source_name ~= "macOS Screen Capture" and source_name ~= "Screen Capture" then
                window_title = source_name
                obs.script_log(obs.LOG_INFO, "Recording Organizer: Using customized source name: '" .. window_title .. "'")
            end
        end
        
        -- Fallback to source name if nothing else worked
        if not window_title or window_title == "" then
            local source_name = obs.obs_source_get_name(source)
            if source_name and source_name ~= "macOS Screen Capture" and source_name ~= "Screen Capture" then
                window_title = source_name
                obs.script_log(obs.LOG_INFO, "Recording Organizer: Using source name as fallback: '" .. window_title .. "'")
            end
        end
    end
    
    if window_title and window_title ~= "" then
        obs.script_log(obs.LOG_INFO, "Recording Organizer: Successfully extracted window title: '" .. window_title .. "'")
    else
        obs.script_log(obs.LOG_WARNING, "Recording Organizer: Could not extract window title from settings")
    end

    return window_title, exe_name
end

function extract_app_name_from_bundle(bundle_id)
    if not bundle_id or bundle_id == "" then
        obs.script_log(obs.LOG_WARNING, "Recording Organizer: extract_app_name_from_bundle received empty bundle ID")
        return nil
    end
    
    obs.script_log(obs.LOG_INFO, "Recording Organizer: Extracting app name from bundle ID: '" .. bundle_id .. "'")
    
    -- Bundle IDs are in reverse domain notation: com.company.AppName
    -- Extract the last component as the app name
    local app_name = bundle_id:match("%.([^%.]+)$")
    
    if not app_name or app_name == "" then
        -- If no dots found, use the whole string
        app_name = bundle_id
    end
    
    obs.script_log(obs.LOG_INFO, "Recording Organizer: Extracted app name: '" .. app_name .. "'")
    return app_name
end

function extract_window_title(window_string)
    if not window_string or window_string == "" then
        obs.script_log(obs.LOG_WARNING, "Recording Organizer: extract_window_title received empty string")
        return nil
    end
    
    obs.script_log(obs.LOG_INFO, "Recording Organizer: Parsing window string: '" .. window_string .. "'")
    obs.script_log(obs.LOG_INFO, "Recording Organizer: String length: " .. tostring(#window_string))
    
    -- Try to extract title after "]:" pattern (common Windows format)
    -- Example: "[Project_Plague-Win64-Shipping.exe]: Project_Plague"
    -- Game Capture may append ":class:exe" segments (e.g. "[bf6.exe]: Battlefield 6:UnrealWindow:bf6")
    local title = window_string:match("%]:%s*(.+)")
    if title and title ~= "" then
        -- Strip any trailing ":class:exe" segments
        title = title:match("^([^:]+)") or title
        -- Trim any trailing whitespace
        title = title:match("^%s*(.-)%s*$")
        obs.script_log(obs.LOG_INFO, "Recording Organizer: Extracted using ']:'  pattern: '" .. title .. "'")
        return title
    end
    
    -- Try to extract executable name from "[executable.exe]" if no title after colon
    local exe = window_string:match("%[(.-)%]")
    if exe and exe ~= "" then
        -- Remove .exe extension
        local clean_exe = exe:gsub("%.exe$", ""):gsub("%.EXE$", "")
        obs.script_log(obs.LOG_INFO, "Recording Organizer: Extracted executable name: '" .. clean_exe .. "'")
        return clean_exe
    end
    
    -- Handle colon-separated formats:
    --   OBS Game/Window Capture: "title:class:exe" (2+ colons, title comes first)
    --   Generic "Game: Title" style (1 colon, title comes after)
    local _, colon_count = window_string:gsub(":", "")
    if colon_count >= 2 then
        -- OBS "title:class:exe" format - take only the title (before first colon)
        title = window_string:match("^([^:]+)")
        if title and title ~= "" then
            title = title:match("^%s*(.-)%s*$")
            obs.script_log(obs.LOG_INFO, "Recording Organizer: Extracted using ':' pattern (title before first colon): '" .. title .. "'")
            return title
        end
    end
    title = window_string:match(":%s*(.+)")
    if title and title ~= "" then
        obs.script_log(obs.LOG_INFO, "Recording Organizer: Extracted using ':' pattern: '" .. title .. "'")
        return title
    end
    
    -- macOS format: Try to extract after " - " separator ("Application - Window Title")
    -- Example: "Google Chrome - YouTube" or "Blender - scene.blend"
    title = window_string:match("^.+%s%-%s(.+)$")
    if title and title ~= "" then
        title = title:match("^%s*(.-)%s*$")  -- Trim whitespace
        obs.script_log(obs.LOG_INFO, "Recording Organizer: Extracted using macOS ' - ' pattern: '" .. title .. "'")
        return title
    end
    
    -- Return the whole string if no pattern matched (works for macOS simple window titles)
    obs.script_log(obs.LOG_INFO, "Recording Organizer: No pattern matched, using full string: '" .. window_string .. "'")
    return window_string
end

function extract_executable_name(window_string, source_id)
    -- Only Windows Window/Game Capture sources embed an executable name
    if source_id ~= "window_capture" and source_id ~= "game_capture" then
        return nil
    end
    if not window_string or window_string == "" then
        return nil
    end

    -- Bracket form: "[bf6.exe]: Battlefield 6"
    local exe = window_string:match("%[(.-%.[Ee][Xx][Ee])%]")
    if exe and exe ~= "" then
        exe = exe:gsub("%.[Ee][Xx][Ee]$", "")
        obs.script_log(obs.LOG_INFO, "Recording Organizer: Extracted executable (bracket): '" .. exe .. "'")
        return exe
    end

    -- Trailing colon-segment form: "Battlefield 6:Battlefield 6:bf6.exe"
    exe = window_string:match(":([^:]+%.[Ee][Xx][Ee])$")
    if exe and exe ~= "" then
        exe = exe:gsub("%.[Ee][Xx][Ee]$", "")
        obs.script_log(obs.LOG_INFO, "Recording Organizer: Extracted executable (colon-tail): '" .. exe .. "'")
        return exe
    end

    obs.script_log(obs.LOG_INFO, "Recording Organizer: No executable name found in window string")
    return nil
end

function clean_exe(exe)
    -- Minimal cleaning for an executable name being appended to a folder name
    -- Avoid the full sanitize_folder_name() path (it converts underscores to spaces)
    if not exe or exe == "" then
        return ""
    end

    local cleaned = exe

    if strict_ascii then
        cleaned = cleaned:gsub("[\128-\255]", "")
    end

    -- Strip Windows-invalid filename characters (don't replace with _, just remove)
    local invalid_chars = {"<", ">", ":", '"', "/", "\\", "|", "?", "*"}
    for _, char in ipairs(invalid_chars) do
        cleaned = cleaned:gsub("%"..char, "")
    end

    return cleaned
end

function sanitize_folder_name(name)
    if not name or name == "" then
        return "Unknown"
    end
    
    obs.script_log(obs.LOG_INFO, "Recording Organizer: Sanitizing name: '" .. name .. "'")
    
    local cleaned = name
    
    -- Remove file extensions (.exe, .EXE on Windows, .app on macOS)
    cleaned = cleaned:gsub("%.exe$", ""):gsub("%.EXE$", ""):gsub("%.app$", "")
    obs.script_log(obs.LOG_INFO, "Recording Organizer: After removing extensions: '" .. cleaned .. "'")
    
    -- Remove common Unreal Engine patterns BEFORE replacing underscores
    -- Handle both UnrealWindow_ and UnrealWindow: (colon variant)
    cleaned = cleaned:gsub("^UnrealWindow[_:]", "")  -- UnrealWindow_ or UnrealWindow: prefix
    cleaned = cleaned:gsub("UnrealWindow[_:]", "")   -- Also try without ^ in case there's whitespace
    obs.script_log(obs.LOG_INFO, "Recording Organizer: After removing UnrealWindow: '" .. cleaned .. "'")
    
    cleaned = cleaned:gsub("%-Win64%-Shipping$", "")  -- -Win64-Shipping suffix
    cleaned = cleaned:gsub("%-Win32%-Shipping$", "")  -- -Win32-Shipping suffix
    cleaned = cleaned:gsub("%-Shipping$", "")  -- -Shipping suffix
    obs.script_log(obs.LOG_INFO, "Recording Organizer: After removing -Shipping suffixes: '" .. cleaned .. "'")

    
    -- Remove common Unity patterns
    cleaned = cleaned:gsub("%.x86_64$", "")
    cleaned = cleaned:gsub("%.x86$", "")
    
    -- Remove common versioning patterns
    cleaned = cleaned:gsub("%s+v?%d+%.%d+[%.%d]*$", "")  -- Remove trailing version numbers like "v1.0.5" or "1.2.3"
    
    -- Replace underscores with spaces (makes "Project_Plague" -> "Project Plague")
    cleaned = cleaned:gsub("_", " ")
    obs.script_log(obs.LOG_INFO, "Recording Organizer: After replacing underscores: '" .. cleaned .. "'")

    
    -- Replace multiple hyphens with single space
    cleaned = cleaned:gsub("%-+", " ")
    
    -- Remove multiple consecutive spaces
    cleaned = cleaned:gsub("%s+", " ")
    
    -- Strip non-ASCII characters to avoid encoding issues on Windows (mojibake)
    if strict_ascii then
        cleaned = cleaned:gsub("[\128-\255]", "")
        obs.script_log(obs.LOG_INFO, "Recording Organizer: After ASCII strip: '" .. cleaned .. "'")
    end

    -- Characters not allowed in Windows folder names
    local invalid_chars = {"<", ">", ":", '"', "/", "\\", "|", "?", "*"}
    for _, char in ipairs(invalid_chars) do
        cleaned = cleaned:gsub("%"..char, "_")
    end
    
    -- Remove leading/trailing spaces and dots
    cleaned = cleaned:gsub("^[%. ]+", ""):gsub("[%. ]+$", "")
    
    -- Trim whitespace
    cleaned = cleaned:match("^%s*(.-)%s*$")
    
    if cleaned == "" then
        obs.script_log(obs.LOG_WARNING, "Recording Organizer: Name became empty after sanitization!")
        return "Unknown"
    end
    
    obs.script_log(obs.LOG_INFO, "Recording Organizer: Sanitized to: '" .. cleaned .. "'")
    
    return cleaned
end

function organize_recording_segments()
    -- Check if we have any segments to organize
    if #recording_segments == 0 then
        obs.script_log(obs.LOG_WARNING, "Recording Organizer: No recording segments found")
        return
    end
    
    -- Get the window/app name
    local window_name = get_active_window_name()
    obs.script_log(obs.LOG_INFO, "Recording Organizer: Detected window/app: " .. window_name)
    
    -- Determine the base folder from first segment
    local base_folder
    if recordings_base_folder and recordings_base_folder ~= "" then
        base_folder = recordings_base_folder
    else
        -- Use the directory where the recording was saved
        base_folder = recording_segments[1]:match("^(.+)[/\\]")
    end
    
    -- Create the subdirectory path
    local target_folder = base_folder .. "/" .. window_name
    
    -- Create the directory if it doesn't exist
    local mkdir_cmd
    if package.config:sub(1,1) == "\\" then
        -- Windows
        target_folder = target_folder:gsub("/", "\\")
        mkdir_cmd = string.format('if not exist "%s" mkdir "%s"', target_folder, target_folder)
    else
        -- Linux/macOS (Unix-based systems)
        mkdir_cmd = string.format('mkdir -p "%s"', target_folder)
    end
    
    os.execute(mkdir_cmd)
    obs.script_log(obs.LOG_INFO, "Recording Organizer: Target folder: " .. target_folder)
    
    -- Move all tracked segment files
    local moved_count = 0
    for _, file_path in ipairs(recording_segments) do
        local filename = file_path:match("^.+[/\\](.+)$")
        local target_path = target_folder .. "/" .. filename
        
        if package.config:sub(1,1) == "\\" then
            target_path = target_path:gsub("/", "\\")
        end
        
        -- Handle duplicate filenames
        if file_exists(target_path) then
            target_path = get_unique_filename(target_path)
        end
        
        -- Move the file
        local success, err = os.rename(file_path, target_path)
        
        if success then
            moved_count = moved_count + 1
            obs.script_log(obs.LOG_INFO, "Recording Organizer: Successfully moved: " .. filename)
        else
            obs.script_log(obs.LOG_ERROR, "Recording Organizer: Failed to move '" .. filename .. "': " .. tostring(err))
        end
    end
    
    obs.script_log(obs.LOG_INFO, string.format("Recording Organizer: Moved %d/%d file(s) to: %s", moved_count, #recording_segments, target_folder))
    
    -- Clear the segments after organizing
    recording_segments = {}
end

function file_exists(path)
    local file = io.open(path, "r")
    if file then
        file:close()
        return true
    end
    return false
end

function get_unique_filename(filepath)
    local path_part, stem, extension = filepath:match("^(.+[/\\])(.+)(%..+)$")
    
    if not path_part then
        -- No extension
        path_part, stem = filepath:match("^(.+[/\\])(.+)$")
        extension = ""
    end
    
    local counter = 1
    while true do
        local new_path = path_part .. stem .. "_" .. counter .. extension
        if not file_exists(new_path) then
            return new_path
        end
        counter = counter + 1
    end
end

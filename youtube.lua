-- If you experience some problems with with the old buggy dkjson version, like in issue #3
-- You need to download the latest version of dkjson until https://code.videolan.org/videolan/vlc/-/merge_requests/3318 is merged.

JSON = require "dkjson" -- load additional json routines

-- Defensive wrappers for vlc.msg.error and vlc.msg.warn
-- This helps prevent script crashes if vlc.msg.error/warn are unexpectedly nil.
local function log_info(fmt, ...)
    if vlc and vlc.msg and vlc.msg.info then
        vlc.msg.info(fmt, ...)
    else
        print(string.format("INFO: " .. fmt, ...))
    end
end

local function log_warn(fmt, ...)
    if vlc and vlc.msg and vlc.msg.warn then
        vlc.msg.warn(fmt, ...)
    else
        print(string.format("WARNING: " .. fmt, ...))
    end
end

local function log_error(fmt, ...)
    if vlc and vlc.msg and vlc.msg.error then
        vlc.msg.error(fmt, ...)
    else
        print(string.format("ERROR: " .. fmt, ...))
    end
end


-- Probe function.
function probe()
    if vlc.access == "http" or vlc.access == "https" then
        peeklen = 9
        s = ""
        while string.len(s) < 9 do
            s = string.lower(string.gsub(vlc.peek(peeklen), "%s", ""))
            peeklen = peeklen + 1
        end
        return s == "<!doctype"
    else
        return false
    end
end

function _get_format_url(format)
    -- prefer streaming formats
    if format.manifest_url then
        return format.manifest_url
    else
        return format.url
    end
end

-- Helper function to get a platform-specific writable directory for downloads.
-- Prefers 'Documents' folder, falls back to system temporary directory.
local function get_download_directory()
    local temp_dir = os.getenv("TEMP") or os.getenv("TMP") or "/tmp" -- Fallback for Linux/macOS
    local documents_dir = nil

    -- Try to get Documents directory for Windows
    if os.getenv("USERPROFILE") then
        documents_dir = os.getenv("USERPROFILE") .. "\\Documents"
        -- Basic check if the directory exists and is writable
        local test_file_path = documents_dir .. "\\vlc_test_write.tmp"
        local f = io.open(test_file_path, "w")
        if f then
            f:close()
            os.remove(test_file_path) -- Clean up test file
            log_info("Using Windows Documents directory: %s", documents_dir)
            return documents_dir
        end
    end
    -- Try to get Documents directory for Linux/macOS
    if os.getenv("HOME") then
        documents_dir = os.getenv("HOME") .. "/Documents"
        local test_file_path = documents_dir .. "/vlc_test_write.tmp"
        local f = io.open(test_file_path, "w")
        if f then
            f:close()
            os.remove(test_file_path) -- Clean up test file
            log_info("Using Linux/macOS Documents directory: %s", documents_dir)
            return documents_dir
        end
    end

    -- Fallback to temporary directory if Documents is not found or not writable
    log_warn("Could not determine writable Documents directory. Falling back to temporary directory: %s", temp_dir)
    return temp_dir
end

-- Function to download a URL to a local file using curl.
-- Returns true on success, false on failure.
local function download_file(url, local_path)
    log_info("Attempting to download URL: %s to %s", url, local_path)
    -- Use curl. Ensure curl is in your system's PATH.
    -- -L: Follow redirects
    -- -o: Write output to specified file
    -- -s: Silent mode (no progress meter)
    -- -S: Show errors (to stderr, which io.popen 'r' won't capture, but we'll check file existence/size)
    local command = string.format('curl -L -sS -o "%s" "%s"', local_path, url)
    local f = io.popen(command, 'r')
    if f then
        local output = f:read("*a") -- This will capture any stdout from curl (usually empty on success with -o)
        f:close()
        log_info("Curl command stdout (should be empty on success): '%s'", output)

        -- Add a small delay to ensure file system operations complete
        -- For Windows, `ping -n 2 127.0.0.1 > nul` waits for 1 second.
        os.execute("ping -n 2 127.0.0.1 > nul")

        -- Verify if the file was actually created, is readable, and non-empty
        local file_handle = io.open(local_path, "rb") -- "rb" for binary read, good for any file type
        if file_handle then
            local size = file_handle:seek("end") -- Get file size
            file_handle:close()

            if size and size > 0 then
                log_info("File downloaded successfully and is readable: %s (Size: %d bytes)", local_path, size)
                return true
            else
                log_error("Downloaded file is empty or could not get size: %s", local_path)
                -- Attempt to remove empty file to avoid clutter
                os.remove(local_path)
                return false
            end
        else
            log_error("Downloaded file not found or not readable after download: %s", local_path)
            return false
        end
    else
        log_error("Failed to execute curl command: %s", command)
        return false
    end
end

-- Parse function.
function parse()
    local url = vlc.access .. "://" .. vlc.path -- get full url

    -- Function to execute command and return file handle or nil on failure
    local function execute_command(command)
        local file = io.popen(command, 'r')
        if file then
            local output = file:read("*a")    -- Attempt to read something to check if command worked
            if output == "" then              -- If nothing was read, assume command failed (like command not found)
                file:close()                  -- Important to close to avoid resource leaks
                return nil                    -- Indicate failure
            else
                file:close()                  -- Close and reopen for actual usage
                return io.popen(command, 'r') -- Reopen since we consumed the initial read
            end
        else
            return nil -- Command execution failed
        end
    end

    -- Try executing youtube-dl command with 1080p resolution limit and subtitle options
    -- Added --write-subs and --write-auto-subs to ensure subtitle URLs are in JSON.
    local file = execute_command('youtube-dl -j --flat-playlist --write-subs --write-auto-subs -f "bestvideo[height<=1080]+bestaudio/best[height<=1080]" "' .. url .. '"')
    if not file then
        -- If youtube-dl fails, try yt-dlp as a fallback with 1080p resolution limit and subtitle options
        file = assert(execute_command('yt-dlp -j --flat-playlist --write-subs --write-auto-subs -f "bestvideo[height<=1080]+bestaudio/best[height<=1080]" "' .. url .. '"'),
            "Both youtube-dl and yt-dlp failed to execute.")
    end

    local tracks = {}
    while true do
        local output = file:read('*l')

        if not output then
            break
        end

        local json = JSON.decode(output) -- decode the json-output from youtube-dl

        if not json then
            break
        end

        local outurl = json.url
        local out_includes_audio = true
        local audiourl = nil
        local subtitle_remote_url = nil
        local subtitle_ext = nil
        local downloaded_subtitle_path = nil -- New variable to store downloaded path
		local english_subtitles

        -- --- Subtitle selection logic starts here ---
        if json and json.subtitles.en then
			english_subtitles = json.subtitles.en
			log_info("selected sub")
			
		elseif json and json.automatic_captions.en then
			english_subtitles = json.automatic_captions.en
			log_info("selected auto sub")
		end	
		
		if english_subtitles then
            if english_subtitles then
                log_info("English subtitles array found.")

                -- Prioritize .vtt, then .srt, then other formats if available
                for i, sub_track in ipairs(english_subtitles) do
                    log_info("Checking subtitle track: ext=%s, url=%s", sub_track.ext, sub_track.url)
                    if sub_track.ext == "vtt" then
                        subtitle_remote_url = sub_track.url
                        subtitle_ext = "vtt"
                        log_info("Found VTT subtitle URL: %s", subtitle_remote_url)
                        break -- Found preferred format, exit loop
                    elseif sub_track.ext == "srt" and not subtitle_remote_url then -- Only consider SRT if VTT not found yet
                        subtitle_remote_url = sub_track.url
                        subtitle_ext = "srt"
                        log_info("Found SRT subtitle URL: %s", subtitle_remote_url)
                    end
                end

                if subtitle_remote_url then
                    log_info("Attempting to download subtitle from: %s (ext: %s)", subtitle_remote_url, subtitle_ext)
                    local download_dir = get_download_directory()
                    local filename = json.id .. "_" .. (subtitle_ext or "sub") .. "." .. (subtitle_ext or "srt")
                    local temp_local_subtitle_path = download_dir .. "\\" .. filename

                    if package.config:sub(1,1) == "/" then
                        temp_local_subtitle_path = download_dir .. "/" .. filename
                    end

                    if download_file(subtitle_remote_url, temp_local_subtitle_path) then
                        log_info("Subtitle downloaded successfully to: %s", temp_local_subtitle_path)
                        downloaded_subtitle_path = temp_local_subtitle_path -- Store for later use
                    else
                        log_info("Failed to download subtitle file from %s.", subtitle_remote_url)
                    end
                else
                    log_info("No suitable English subtitle URL (.vtt or .srt) found for download.")
                end
            else
                log_info("No 'en' key found in the 'subtitles' object.")
            end
        end
        -- --- Subtitle selection logic ends here ---

        if not outurl then
            if json.requested_formats then
                for key, format in pairs(json.requested_formats) do
                    if format.vcodec ~= (nil or "none") then
                        outurl = _get_format_url(format)
                        out_includes_audio = format.acodec ~= (nil or "none")
                    end

                    if format.acodec ~= (nil or "none") then
                        audiourl = _get_format_url(format)
                    end
                end
            else
                -- choose best
                for key, format in pairs(json.formats) do
                    outurl = _get_format_url(format)
                end
                -- prefer audio and video
                for key, format in pairs(json.formats) do
                    if format.vcodec ~= (nil or "none") and format.acodec ~= (nil or "none") then
                        outurl = _get_format_url(format)
                    end
                end
            end
        end

        if outurl then
            if (json._type == "url" or json._type == "url_transparent") and json.ie_key == "Youtube" then
                outurl = "https://www.youtube.com/watch?v=" .. outurl
            end

            local category = nil
            if json.categories then
                category = json.categories[1]
            end

            local year = nil
            if json.release_year then
                year = json.release_year
            elseif json.release_date then
                year = string.sub(json.release_date, 1, 4)
            elseif json.upload_date then
                year = string.sub(json.upload_date, 1, 4)
            end

            local thumbnail = nil
            if json.thumbnails then
                thumbnail = json.thumbnails[#json.thumbnails].url
            end

            jsoncopy = {}
            for k in pairs(json) do
                jsoncopy[k] = tostring(json[k])
            end

            json = jsoncopy

            item = {
                path        = outurl,
                name        = json.title,
                duration    = json.duration,

                -- for a list of these check vlc/modules/lua/libs/sd.c
                title       = json.track or json.title,
                artist      = json.artist or json.creator or json.uploader or json.playlist_uploader,
                genre       = json.genre or category,
                copyright   = json.license,
                album       = json.album or json.playlist_title or json.playlist,
                tracknum    = json.track_number or json.playlist_index,
                description = json.description,
                rating      = json.average_rating,
                date        = year,
                --setting
                url         = json.webpage_url or url,
                --language
                --nowplaying
                --publisher
                --encodedby
                arturl      = json.thumbnail or thumbnail,
                trackid     = json.track_id or json.episode_id or json.id,
                tracktotal  = json.n_entries,
                --director
                season      = json.season or json.season_number or json.season_id,
                episode     = json.episode or json.episode_number,
                show_name   = json.series,
                --actors

                meta        = json,
                options     = { "start-time=" .. (json.start_time or 0) },
            }

            -- Ensure audiourl is added as an input-slave if separate
            if not out_includes_audio and audiourl and outurl ~= audiourl then
                table.insert(item.options, ":input-slave=" .. audiourl);
            end

            -- --- Add subtitle to options if it was successfully downloaded ---
            if downloaded_subtitle_path then
                table.insert(item.options, ":sub-file=" .. downloaded_subtitle_path)
                log_info("Added subtitle file to item options: %s", downloaded_subtitle_path)
            end
            -- --- End subtitle addition ---

            table.insert(tracks, item)
        end
    end
    file:close()
    return tracks
end

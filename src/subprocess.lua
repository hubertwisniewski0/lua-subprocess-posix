--- subprocess: A Lua module for running commands as subprocesses
--- Similar to Python's subprocess module, using luaposix for process control

local posix = require("posix")
local subprocess = {}

local DEBUG = os.getenv("SUBPROCESS_DEBUG") == "1"
local DEBUGFD = 2
local PID = posix.getpid().pid

--- Print debug message if debug mode is enabled
local function debug_log(...)
    if DEBUG then
        posix.write(
            DEBUGFD,
            string.format(
                "[subprocess] [%d] %s\n",
                PID, string.format(...)
            )
        )
    end
end

debug_log("loading subprocess")

--- Close pipe(s) by name or all if no name given
--- @param pipes table the pipes table
--- @param pipe_name string|nil name of pipe to close, or nil to close all
local function close_pipes(pipes, pipe_name)
    if pipe_name then
        local fd = pipes[pipe_name]
        if fd then
            debug_log("close_pipes: closing %s, fd=%d", pipe_name, fd)
            local ret, err = posix.close(fd)
            if not ret then
                -- Not critical
                debug_log("close_pipes: close failed: %s", err)
            end
            pipes[pipe_name] = nil
        else
            debug_log("close_pipes: no such pipe: %s", pipe_name)
        end
    else
        debug_log("close_pipes: closing all")
        for name, fd in pairs(pipes) do
            if fd then
                close_pipes(pipes, name)
            end
        end
    end
end

--- Create all pipes (stdin, stdout, stderr, and exec_error for reporting execp failures)
--- @return table|nil #pipes table with stdin_r, stdin_w, stdout_r, stdout_w, stderr_r, stderr_w, exec_error_r, exec_error_w or nil on error
--- @return string|nil #error message if creation failed
local function create_pipes()
    local pipes = {}

    local stdin_r, stdin_w = posix.pipe()
    if not stdin_r then
        close_pipes(pipes)
        return nil, "Failed to create stdin pipe: " .. stdin_w
    end
    pipes.stdin_r = stdin_r
    pipes.stdin_w = stdin_w
    posix.fcntl(stdin_w, posix.F_SETFL, posix.O_NONBLOCK)
    posix.fcntl(stdin_w, posix.F_SETFD, posix.FD_CLOEXEC)
    debug_log("create_pipes: stdin r=%d, w=%d", stdin_r, stdin_w)

    local stdout_r, stdout_w = posix.pipe()
    if not stdout_r then
        close_pipes(pipes)
        return nil, "Failed to create stdout pipe: " .. stdout_w
    end
    pipes.stdout_r = stdout_r
    pipes.stdout_w = stdout_w
    posix.fcntl(stdout_r, posix.F_SETFL, posix.O_NONBLOCK)
    posix.fcntl(stdout_r, posix.F_SETFD, posix.FD_CLOEXEC)
    debug_log("create_pipes: stdout r=%d, w=%d", stdout_r, stdout_w)

    local stderr_r, stderr_w = posix.pipe()
    if not stderr_r then
        close_pipes(pipes)
        return nil, "Failed to create stderr pipe: " .. stderr_w
    end
    pipes.stderr_r = stderr_r
    pipes.stderr_w = stderr_w
    posix.fcntl(stderr_r, posix.F_SETFL, posix.O_NONBLOCK)
    posix.fcntl(stderr_r, posix.F_SETFD, posix.FD_CLOEXEC)
    debug_log("create_pipes: stderr r=%d, w=%d", stderr_r, stderr_w)

    local exec_error_r, exec_error_w = posix.pipe()
    if not exec_error_r then
        close_pipes(pipes)
        return nil, "Failed to create exec_error pipe: " .. exec_error_w
    end
    pipes.exec_error_r = exec_error_r
    pipes.exec_error_w = exec_error_w
    posix.fcntl(exec_error_w, posix.F_SETFD, posix.FD_CLOEXEC)
    debug_log("create_pipes: exec_error r=%d, w=%d", exec_error_r, exec_error_w)

    return pipes, nil
end

--- Read as much data as possible from a pipe
--- @param pipes table pipe file descriptors
--- @param name string name of the pipe to read from
--- @return string|nil #data read or nil on error
--- @return string|nil #error message if read failed
local function read_all(pipes, name)
    local data = ""

    while true do
        local chunk, err, err_code = posix.read(pipes[name], 4096)
        if not chunk then
            if err_code == posix.EAGAIN or err_code == posix.EWOULDBLOCK then
                debug_log("read_all: %s would block", name)
                break
            else
                debug_log("read_all: reading from %s failed: %s", name, err)
                return nil, err
            end
        elseif #chunk > 0 then
            data = data .. chunk
            debug_log("read_all: read %d bytes from %s", #chunk, name)
        else
            debug_log("read_all: no more data to read from %s", name)
            close_pipes(pipes, name)
            break
        end
    end

    return data, nil
end

--- Write as much data as possible to a pipe
--- @param pipes table pipe file descriptors
--- @param name string name of the pipe to write to
--- @param data table input data state {data=string, pos=number}
--- @return integer|nil #number of data bytes written or nil on error
--- @return string|nil #error message if write failed
local function write_all(pipes, name, data)
    local total_written = 0

    while true do
        if data.pos >= #data.data then
            debug_log("write_all: all data written, closing %s", name)
            close_pipes(pipes, name)
            break
        end

        local nbytes = #data.data - data.pos

        -- Handle broken pipe gracefully
        local prev_handler = posix.signal(posix.SIGPIPE, posix.SIG_IGN)
        local written, err, err_code = posix.write(pipes.stdin_w, data.data, nbytes, data.pos)
        posix.signal(posix.SIGPIPE, prev_handler)

        if not written then
            if err_code == posix.EAGAIN or err_code == posix.EWOULDBLOCK then
                debug_log("write_all: %s would block", name)
                break
            elseif err_code == posix.EPIPE then
                debug_log("write_all: broken pipe, closing %s", name)
                close_pipes(pipes, name)
                break
            else
                debug_log("write_all: writing to %s failed: %s", name, err)
                return nil, err
            end
        else
            data.pos = data.pos + written
            total_written = total_written + written
            debug_log("write_all: wrote %d bytes to %s", written, name)
        end
    end

    return total_written, nil
end

--- Poll for I/O events and handle reading/writing
--- @param pipes table pipe file descriptors
--- @param data table input data state {data=string, pos=number}
--- @param result table result table to populate
--- @return boolean|nil #true if pipes remain, false if all closed, nil on error
--- @return string|nil #error message if operation failed
local function poll_and_read_write(pipes, data, result)
    -- Setup poll file descriptors table
    local fds = {}
    if pipes.stdin_w then
        fds[pipes.stdin_w] = {events = {OUT = true}}
    end
    if pipes.stdout_r then
        fds[pipes.stdout_r] = {events = {IN = true}}
    end
    if pipes.stderr_r then
        fds[pipes.stderr_r] = {events = {IN = true}}
    end

    -- Return false if no pipes left open
    if not next(fds) then
        debug_log("poll_and_read_write: no pipes to poll")
        return false, nil
    end

    -- Avoid table operations if debugging is off
    if DEBUG then
        local fd_list = {}
        for fd, _ in pairs(fds) do
            table.insert(fd_list, fd)
        end
        debug_log("poll_and_read_write: polling fds=[%s]", table.concat(fd_list, ", "))
    end

    local nfds, err = posix.poll.poll(fds)

    if not nfds then
        debug_log("poll_and_read_write: poll failed: %s", err)
        return nil, err
    end

    debug_log("poll_and_read_write: poll returned %d events", nfds)

    for fd, fd_info in pairs(fds) do
        local revents = fd_info.revents or {}
        local chunk, written

        if fd == pipes.stdin_w and (revents.OUT or revents.ERR) then
            debug_log("poll_and_read_write: writing to stdin (pos=%d/%d)", data.pos, #data.data)
            written, err = write_all(pipes, "stdin_w", data)
            if not written then
                return nil, err
            end
        end

        if fd == pipes.stdout_r and (revents.IN or revents.HUP) then
            debug_log("poll_and_read_write: reading from stdout")
            chunk, err = read_all(pipes, "stdout_r")
            if chunk then
                result.stdout_data = result.stdout_data .. chunk
            else
                return nil, err
            end
        end

        if fd == pipes.stderr_r and (revents.IN or revents.HUP) then
            debug_log("poll_and_read_write: reading from stderr")
            chunk, err = read_all(pipes, "stderr_r")
            if chunk then
                result.stderr_data = result.stderr_data .. chunk
            else
                return nil, err
            end
        end
    end

    return true, nil
end

--- Child process logic after fork
--- @param cmd string the command to execute
--- @param args table command arguments
--- @param pipes table pipe file descriptors
local function child_process(cmd, args, pipes)
    local ret, err
    close_pipes(pipes, "exec_error_r")
    debug_log("child_process: redirecting file descriptors")

    -- Avoid leaking debug messages into captured stderr
    if DEBUG then
        ret, err = posix.dup(DEBUGFD)
        if not ret then
            debug_log("child_process: DEBUGFD dup failed: %s", err)
            goto write_error
        end

        DEBUGFD = ret
        posix.fcntl(DEBUGFD, posix.F_SETFD, posix.FD_CLOEXEC)
        debug_log("child_process: new DEBUGFD=%d", DEBUGFD)
    end

    debug_log("child_process: duping stdin")
    ret, err = posix.dup2(pipes.stdin_r, posix.fileno(io.stdin))
    if not ret then
        debug_log("child_process: stdin dup failed: %s", err)
        goto write_error
    end

    debug_log("child_process: duping stdout")
    ret, err = posix.dup2(pipes.stdout_w, posix.fileno(io.stdout))
    if not ret then
        debug_log("child_process: stdout dup failed: %s", err)
        goto write_error
    end

    debug_log("child_process: duping stderr")
    ret, err = posix.dup2(pipes.stderr_w, posix.fileno(io.stderr))
    if not ret then
        debug_log("child_process: stderr dup failed: %s", err)
        goto write_error
    end

    close_pipes(pipes, "stdin_r")
    close_pipes(pipes, "stdout_w")
    close_pipes(pipes, "stderr_w")

    -- Execute the command with arguments
    debug_log("child_process: executing %s", cmd)
    ret, err = posix.execp(cmd, args)
    -- If execp returns, it failed - write error to pipe and exit
    debug_log("child_process: execp failed: %s", err)

    ::write_error::
    posix.write(pipes.exec_error_w, err)
    os.exit(127)
end

--- Parent process logic after fork
--- @param pid number child process ID
--- @param pipes table pipe file descriptors
--- @param input_data string data to write to stdin
--- @return table|nil #result table or nil on error
--- @return string|nil #error message
local function parent_process(pid, pipes, input_data)
    debug_log("parent_process: child PID=%d", pid)
    -- Close parent-irrelevant pipe ends
    close_pipes(pipes, "stdin_r")
    close_pipes(pipes, "stdout_w")
    close_pipes(pipes, "stderr_w")
    close_pipes(pipes, "exec_error_w")

    local err
    local result = {stdout_data = "", stderr_data = "", exit_status = nil}

    -- Check for exec errors
    debug_log("parent_process: waiting for child to exec or fail")
    local exec_err = posix.read(pipes.exec_error_r, 1024)
    if #exec_err > 0 then
        debug_log("parent_process: child exec failed: %s", exec_err)
        err = "Failed to execute: " .. exec_err
        close_pipes(pipes, "exec_error_r")
        goto wait_child
    end
    debug_log("parent_process: child exec succeeded, starting I/O loop")
    close_pipes(pipes, "exec_error_r")

    do
        -- Track input data for writing
        local data = {data = input_data, pos = 0}

        while true do
            -- Poll and handle I/O
            local left, io_err = poll_and_read_write(pipes, data, result)
            if left == nil then
                debug_log("parent_process: I/O failed: %s", io_err)
                debug_log("parent_process: killing child")
                posix.kill(pid, posix.SIGTERM)
                err = "I/O error: " .. io_err
                break
            elseif not left then
                debug_log("parent_process: no more pipes, exiting I/O loop")
                break
            end
        end
    end

    ::wait_child::
    debug_log("parent_process: waiting for child to exit")
    local wpid, status, ret = posix.wait(pid)
    debug_log("parent_process: wpid=%d, status=%s, ret=%d", wpid, status, ret)

    if wpid == pid then
        -- Extract exit status
        if status == "exited" then
            result.exit_status = ret
            debug_log("parent_process: child exited with status %d", ret)
        elseif status == "killed" then
            result.exit_status = 128 + ret
            debug_log("parent_process: child killed by signal %d", ret)
        end
    end

    if err then
        return nil, err
    else
        return result, nil
    end
end

--- Run a command as a subprocess with optional input data
--- @param cmd string the command to execute (path or command name)
--- @param args table|nil command arguments as a table (e.g., {"arg1", "arg2"})
--- @param input_data string|nil data to pipe into stdin
--- @return table|nil #result table with fields:
---   - stdout_data: string captured from stdout (or nil on error)
---   - stderr_data: string captured from stderr (or nil on error)
---   - exit_status: integer exit code
---   or nil on subprocess error
--- @return string|nil #error message
function subprocess.run(cmd, args, input_data)
    -- Validate arguments
    if not cmd then
        return nil, "Command is required"
    end

    args = args or {}
    if DEBUG then
        local args_str = table.concat(args, ", ")
        debug_log("run: cmd=%s, args=[%s]", cmd, args_str)
    end

    input_data = input_data or ""

    -- Create pipes for stdin, stdout, stderr
    local pipes, err = create_pipes()
    if not pipes then
        return nil, err
    end

    local result

    -- Fork the process
    local pid, fork_err = posix.fork()
    if not pid then
        debug_log("run: fork failed: %s", fork_err)
        err = "Failed to fork process: " .. fork_err
        goto cleanup
    end

    PID = posix.getpid().pid
    debug_log("run: fork returned %d", pid)

    if pid == 0 then
        child_process(cmd, args, pipes)
    else
        result, err = parent_process(pid, pipes, input_data)
    end

    ::cleanup::
    close_pipes(pipes)

    if err then
        return nil, err
    else
        return result, nil
    end
end

return subprocess

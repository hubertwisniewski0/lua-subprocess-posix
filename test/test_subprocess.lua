#!/usr/bin/env lua
--- Comprehensive test suite for subprocess module
--- Uses LuaUnit for assertions

local lu = require("luaunit")
local subprocess = require("subprocess")

-- Test class
TestSubprocess = {}

-- ============================================================================
-- Basic Execution Tests
-- ============================================================================

function TestSubprocess:test_simple_command_no_args()
    local result, err = subprocess.run("echo")
    lu.assertNil(err, "echo should not error")
    lu.assertNotNil(result, "result should not be nil")
    lu.assertIsTable(result, "result should be a table")
    lu.assertEquals(result.exit_status, 0, "echo should exit with 0")
    lu.assertTrue(#result.stdout_data >= 0, "stdout should be present")
end

function TestSubprocess:test_command_with_single_arg()
    local result, err = subprocess.run("echo", {"hello"})
    lu.assertNil(err, "should not error")
    lu.assertNotNil(result)
    lu.assertEquals(result.exit_status, 0)
    lu.assertEquals(result.stdout_data, "hello\n")
end

function TestSubprocess:test_command_with_multiple_args()
    local result, err = subprocess.run("echo", {"hello", "world"})
    lu.assertNil(err)
    lu.assertNotNil(result)
    lu.assertEquals(result.exit_status, 0)
    lu.assertEquals(result.stdout_data, "hello world\n")
end

-- ============================================================================
-- Input/Output Tests
-- ============================================================================

function TestSubprocess:test_input_data_via_stdin()
    -- Use cat to read from stdin and output to stdout
    local result, err = subprocess.run("cat", {}, "hello world")
    lu.assertNil(err)
    lu.assertNotNil(result)
    lu.assertEquals(result.exit_status, 0)
    lu.assertEquals(result.stdout_data, "hello world")
end

function TestSubprocess:test_capture_stdout()
    local result, err = subprocess.run("echo", {"test_output"})
    lu.assertNil(err)
    lu.assertNotNil(result)
    lu.assertIsString(result.stdout_data)
    lu.assertEquals(result.stdout_data, "test_output\n")
end

function TestSubprocess:test_capture_stderr()
    -- Use sh to write to stderr
    local result, err = subprocess.run("sh", {"-c", "echo error_msg >&2"})
    lu.assertNil(err)
    lu.assertNotNil(result)
    lu.assertIsString(result.stderr_data)
    lu.assertEquals(result.stderr_data, "error_msg\n")
end

function TestSubprocess:test_capture_stdout_and_stderr()
    local result, err = subprocess.run("sh", {"-c", "echo stdout_msg; echo stderr_msg >&2"})
    lu.assertNil(err)
    lu.assertNotNil(result)
    lu.assertEquals(result.stdout_data, "stdout_msg\n")
    lu.assertEquals(result.stderr_data, "stderr_msg\n")
end

-- ============================================================================
-- Exit Status Tests
-- ============================================================================

function TestSubprocess:test_successful_exit_zero()
    local result, err = subprocess.run("true")
    lu.assertNil(err)
    lu.assertNotNil(result)
    lu.assertEquals(result.exit_status, 0)
end

function TestSubprocess:test_failed_exit_nonzero()
    local result, err = subprocess.run("false")
    lu.assertNil(err)
    lu.assertNotNil(result)
    lu.assertNotEquals(result.exit_status, 0)
end

function TestSubprocess:test_specific_exit_code()
    -- Use sh to exit with specific code
    local result, err = subprocess.run("sh", {"-c", "exit 42"})
    lu.assertNil(err)
    lu.assertNotNil(result)
    lu.assertEquals(result.exit_status, 42)
end

-- ============================================================================
-- Error Handling Tests
-- ============================================================================

function TestSubprocess:test_command_not_found()
    local _, err = subprocess.run("nonexistent_command_xyz_123")
    lu.assertNotNil(err, "should return error for non-existent command")
    lu.assertStrContains(err:lower(), "execute", "error should mention execution failure")
end

function TestSubprocess:test_missing_command_argument()
    local _, err = subprocess.run(nil)
    lu.assertNotNil(err, "should error when cmd is nil")
    lu.assertStrContains(err:lower(), "required", "error should mention cmd is required")
end

function TestSubprocess:test_pipe_creation_failure()
    -- Save current fd limit
    local posix = require("posix")
    local current_soft = posix.getrlimit("nofile")
    local ok, result, err

    -- Set a very low soft fd limit (3 is minimum for stdin/stdout/stderr, so 4 won't allow pipes)
    ok, err = posix.setrlimit("nofile", 4)
    if not ok then
        lu.skip("Cannot set rlimit: " .. err)
    end

    -- Try to run subprocess - should fail when trying to create pipes
    result, err = subprocess.run("echo", {"hello"})

    -- Restore original soft fd limit
    posix.setrlimit("nofile", current_soft)

    -- Verify subprocess.run returned an error
    lu.assertNotNil(err, "should return error when pipes cannot be created")
    lu.assertNil(result, "result should be nil on pipe creation failure")
    lu.assertStrContains(err:lower(), "pipe", "error should mention pipe creation failure")
end

function TestSubprocess:test_fork_failure()
    -- Mock posix.fork to simulate ENOSYS error
    local posix = require("posix")
    local original_fork = posix.fork

    -- Replace fork with a mock that returns error with ENOSYS errno
    posix.fork = function()
        return nil, "Operation not supported", posix.ENOSYS
    end

    -- Try to run subprocess - should fail during fork
    local result, err = subprocess.run("echo", {"hello"})

    -- Restore original fork function
    posix.fork = original_fork

    -- Verify subprocess.run returned an error about fork failure
    lu.assertNotNil(err, "should return error when fork fails")
    lu.assertNil(result, "result should be nil on fork failure")
    lu.assertStrContains(err:lower(), "fork", "error should mention fork failure")
end

-- ============================================================================
-- Argument Handling Tests
-- ============================================================================

function TestSubprocess:test_no_args_parameter()
    -- Call without args (nil)
    local result, err = subprocess.run("echo", nil, "test")
    lu.assertNil(err)
    lu.assertNotNil(result)
    lu.assertEquals(result.exit_status, 0)
end

function TestSubprocess:test_empty_args_table()
    -- Call with empty args table
    local result, err = subprocess.run("echo", {})
    lu.assertNil(err)
    lu.assertNotNil(result)
    lu.assertEquals(result.exit_status, 0)
end

function TestSubprocess:test_no_input_data()
    -- Call without input_data (nil)
    local result, err = subprocess.run("echo", {"test"}, nil)
    lu.assertNil(err)
    lu.assertNotNil(result)
    lu.assertEquals(result.exit_status, 0)
    lu.assertEquals(result.stdout_data, "test\n")
end

function TestSubprocess:test_empty_input_data()
    -- Call with empty string input
    local result, err = subprocess.run("cat", {}, "")
    lu.assertNil(err)
    lu.assertNotNil(result)
    lu.assertEquals(result.exit_status, 0)
end

-- ============================================================================
-- Output Stream Tests
-- ============================================================================

function TestSubprocess:test_empty_output_streams()
    -- Command that produces no output
    local result, err = subprocess.run("true")
    lu.assertNil(err)
    lu.assertNotNil(result)
    lu.assertEquals(#result.stdout_data, 0, "stdout should be empty")
    lu.assertEquals(#result.stderr_data, 0, "stderr should be empty")
end

function TestSubprocess:test_only_stdout_has_data()
    local result, err = subprocess.run("echo", {"output"})
    lu.assertNil(err)
    lu.assertNotNil(result)
    lu.assertTrue(#result.stdout_data > 0, "stdout should have data")
    lu.assertEquals(#result.stderr_data, 0, "stderr should be empty")
end

function TestSubprocess:test_only_stderr_has_data()
    local result, err = subprocess.run("sh", {"-c", "echo error >&2"})
    lu.assertNil(err)
    lu.assertNotNil(result)
    lu.assertEquals(#result.stdout_data, 0, "stdout should be empty")
    lu.assertTrue(#result.stderr_data > 0, "stderr should have data")
end

-- ============================================================================
-- Return Value Structure Tests
-- ============================================================================

function TestSubprocess:test_result_has_required_fields()
    local result, err = subprocess.run("echo", {"test"})
    lu.assertNil(err)
    lu.assertNotNil(result)
    lu.assertIsTable(result)
    lu.assertIsString(result.stdout_data, "stdout_data should be string")
    lu.assertIsString(result.stderr_data, "stderr_data should be string")
    lu.assertIsNumber(result.exit_status, "exit_status should be number")
end

function TestSubprocess:test_error_return_format()
    local result, err = subprocess.run("nonexistent_command_xyz")
    lu.assertNotNil(err, "should return error message")
    lu.assertIsString(err, "error should be a string")
    lu.assertNil(result, "result should be nil on error")
end

-- ============================================================================
-- Edge Cases and Special Characters
-- ============================================================================

function TestSubprocess:test_args_with_spaces()
    local result, err = subprocess.run("cat", {"/does not exist"})
    lu.assertNil(err)
    lu.assertNotNil(result)
    lu.assertNotEquals(result.exit_status, 0)
    -- "/does not exist" shall be one argument, so that cat treats it as
    -- a single file name
    lu.assertStrContains(result.stderr_data, "/does not exist")
end

function TestSubprocess:test_args_with_special_characters()
    local result, err = subprocess.run("sh", {"-c", "echo -n 'test$var!'"})
    lu.assertNil(err)
    lu.assertNotNil(result)
    lu.assertEquals(result.exit_status, 0)
    lu.assertEquals(result.stdout_data, "test$var!")
end

function TestSubprocess:test_input_with_newlines()
    local input = "line1\nline2\nline3"
    local result, err = subprocess.run("cat", {}, input)
    lu.assertNil(err)
    lu.assertNotNil(result)
    lu.assertEquals(result.exit_status, 0)
    lu.assertEquals(result.stdout_data, input)
end

function TestSubprocess:test_multiline_output()
    local result, err = subprocess.run("sh", {"-c", "echo line1; echo line2; echo line3"})
    lu.assertNil(err)
    lu.assertNotNil(result)
    lu.assertEquals(result.exit_status, 0)
    lu.assertEquals(result.stdout_data, "line1\nline2\nline3\n")
end

-- ============================================================================
-- Data Handling Tests
-- ============================================================================

function TestSubprocess:test_binary_safe_stdout()
    local data = "binary\x00\xff\xaadata"
    local result, err = subprocess.run("cat", {}, data)
    lu.assertNil(err)
    lu.assertNotNil(result)
    lu.assertEquals(result.exit_status, 0)
    lu.assertEquals(result.stdout_data, data)
end

function TestSubprocess:test_very_long_single_line()
    local long_line = string.rep("x", 5000000)
    local result, err = subprocess.run("cat", {}, long_line)
    lu.assertNil(err)
    lu.assertNotNil(result)
    lu.assertEquals(result.exit_status, 0)
    lu.assertEquals(#result.stdout_data, #long_line)
end

-- ============================================================================
-- Broken Pipe Handling Tests
-- ============================================================================

function TestSubprocess:test_broken_pipe_handling()
    -- Send large amount of data to a process that won't read it
    -- 'true' command exits immediately without reading stdin
    -- The write to stdin will fail with EPIPE when pipe buffer fills up
    local large_input = string.rep("x", 1000000)  -- 1MB of data
    local result, err = subprocess.run("true", {}, large_input)

    -- Should complete without error despite broken pipe
    lu.assertNil(err, "should handle broken pipe gracefully")
    lu.assertNotNil(result, "result should be valid")
    lu.assertEquals(result.exit_status, 0, "true should exit with 0")
    lu.assertEquals(#result.stdout_data, 0, "true produces no output")
    lu.assertEquals(#result.stderr_data, 0, "true produces no errors")
end

function TestSubprocess:test_broken_pipe_with_output()
    -- Process that produces output but won't read input
    -- 'echo' will output its args and exit, ignoring stdin
    local large_input = string.rep("x", 1000000)  -- 1MB of data
    local result, err = subprocess.run("echo", {"output_test"}, large_input)

    -- Should complete without error
    lu.assertNil(err, "should handle broken pipe with concurrent output")
    lu.assertNotNil(result)
    lu.assertEquals(result.exit_status, 0)
    lu.assertEquals(result.stdout_data, "output_test\n")
end

-- ============================================================================
-- Run tests
-- ============================================================================

os.exit(lu.LuaUnit.run())

-- ---------------------------------------------------------------------------
-- Test runner for the Enchanter Mez Support plugin.
--
-- Run from the repository root with LuaJIT (the plugin loader uses setfenv):
--
--     luajit tests/run.lua
--
-- Optional: point TAC_SOURCE at a TAC triune.lua that contains the target
-- selector registry to also run the checks against TAC's real registry code:
--
--     TAC_SOURCE=/path/to/TAC/lua/triune.lua luajit tests/run.lua
--
-- Without TAC_SOURCE those checks are skipped (and say so).
-- ---------------------------------------------------------------------------

PLUGIN_FILE = 'mez.lua'

local pass, fail, errors = 0, 0, {}

function assert_eq(got, expect, label)
    if got == expect then
        pass = pass + 1
    else
        fail = fail + 1
        errors[#errors + 1] = string.format(
            "  FAIL: %s\n    expected: %s (%s)\n    got:      %s (%s)",
            label, tostring(expect), type(expect), tostring(got), type(got))
    end
end

function assert_neq(got, notExpect, label)
    if got ~= notExpect then
        pass = pass + 1
    else
        fail = fail + 1
        errors[#errors + 1] = string.format("  FAIL: %s\n    should NOT be: %s", label, tostring(notExpect))
    end
end

function assert_true(val, label) assert_eq(not not val, true, label) end
function assert_nil(val, label) assert_eq(val, nil, label) end
function assert_type(val, expectedType, label) assert_eq(type(val), expectedType, label) end

-- A TAC source file, line endings normalised, or nil when TAC_SOURCE is unset or unreadable.
function tacSource()
    local path = os.getenv('TAC_SOURCE')
    if not path or path == '' then return nil end
    local f = io.open(path, 'rb')
    if not f then return nil end
    local s = f:read('*a')
    f:close()
    return (s:gsub('\r\n', '\n'))
end

local suites = { 'tests/test_decision.lua', 'tests/test_collection.lua' }
for _, file in ipairs(suites) do
    local chunk, err = loadfile(file)
    if not chunk then
        io.stderr:write('cannot load ' .. file .. ': ' .. tostring(err) .. '\n')
        os.exit(2)
    end
    chunk()
end

print(string.format('\n=== Results: %d passed, %d failed ===', pass, fail))
if fail > 0 then
    print('\nFailures:')
    for _, e in ipairs(errors) do print(e) end
    os.exit(1)
else
    print('All tests passed.')
    os.exit(0)
end

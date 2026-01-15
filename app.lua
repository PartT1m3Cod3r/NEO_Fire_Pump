core.updateInterval = 1000  -- 1 second interval for more responsive monitoring

-- ============================================================================
-- CONFIGURATION
-- ============================================================================
local config = {
    -- Voltage thresholds
    lowVoltageThreshold = 11.5,
    normalVoltageThreshold = 12.5,

    -- Timing (in seconds)
    crankTime = 5,
    maxStartAttempts = 3,
    pumpConfirmDelay = 10,
    smsCheckInterval = 30,  -- Check for SMS every 30 seconds

    -- Run time service interval (in seconds) - 5 hours = 18000 seconds
    serviceInterval = 18000,

    -- Weekly report settings
    weeklyReportDay = 6,  -- Friday (1=Sunday, 2=Monday, ... 6=Friday, 7=Saturday)
    weeklyReportHour = 9,  -- 9 AM

    -- Phone number for alerts (set this to your number)
    alertPhone = "0404716908",  -- Set your phone number here

    -- Optional features
    tankLevelEnabled = false,  -- Set to true if tank level sensor is installed
}

-- ============================================================================
-- I/O MAPPING
-- ============================================================================
local io_map = {
    -- Analog Inputs
    batteryVoltage = io.ANALOG_1,
    pumpPressureSw = io.ANALOG_2,
    oilPressureSw = io.ANALOG_3,
    tankLevel = io.ANALOG_4,

    -- Digital Outputs (active LOW for relay trigger)
    crankRelay = io.OUTPUT_1,
    fuelSolenoid = io.OUTPUT_2,
}

-- ============================================================================
-- STATE VARIABLES
-- ============================================================================
local state = "idle"  -- idle, starting, running, stopping, failed

local start = {
    time = 0,
    solenoidState = "idle",  -- idle, cranking, waitingConfirm
    attempt = 0,
    confirmStartTime = 0,
}

local stop = {
    time = 0,
}

local pumpSystem = {
    batteryVoltage = 0,
    pumpPressureSwitch = false,
    oilPressureSwitch = false,
    tankLevel = 0,
    signalStrength = 0,
}

local alerts = {
    lowVoltageAlerted = false,
    lastWeeklyReport = 0,
}

local runtime = {
    totalSeconds = 0,
    lastServiceAlert = 0,  -- Last service alert threshold (0, 18000, 36000, etc.)
    sessionStart = 0,
}

local smsRequester = ""  -- Phone number that sent the command
local lastSmsCheck = 0   -- Last time we requested SMS check

-- ============================================================================
-- RUNTIME PERSISTENCE FUNCTIONS
-- ============================================================================

function saveRuntime()
    keystore.set("runtime", {
        totalSeconds = runtime.totalSeconds,
        lastServiceAlert = runtime.lastServiceAlert
    })
end

function loadRuntime()
    local saved = keystore.get("runtime")
    if saved then
        runtime.totalSeconds = saved.totalSeconds or 0
        runtime.lastServiceAlert = saved.lastServiceAlert or 0
        print("Runtime loaded: " .. formatRunTime())
    else
        print("No saved runtime found, starting fresh")
    end
end

function clearRuntime()
    runtime.totalSeconds = 0
    runtime.lastServiceAlert = 0
    runtime.sessionStart = 0
    saveRuntime()
    print("Runtime cleared")
end

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

function turnOn(output)
    -- Active LOW trigger for relays (false = relay activated)
    io.writeOutput(output, true)
end

function turnOff(output)
    -- Active LOW trigger for relays (true = relay deactivated)
    io.writeOutput(output, false)
end

function formatDateTime()
    local t = os.date("*t")
    return string.format("DATE: %02d/%02d/%04d TIME: %02d:%02d",
        t.day, t.month, t.year, t.hour, t.min)
end

function updateSystemStats()
    pumpSystem.batteryVoltage = io.readAnalog(io_map.batteryVoltage)

    -- Pressure switches: assume closed = above threshold voltage (adjust threshold as needed)
    local pumpVoltage = io.readAnalog(io_map.pumpPressureSw)
    pumpSystem.pumpPressureSwitch = (pumpVoltage > 3500)  -- Adjust threshold as needed

    local oilVoltage = io.readAnalog(io_map.oilPressureSw)
    pumpSystem.oilPressureSwitch = (oilVoltage > 3500)  -- Adjust threshold as needed

    if config.tankLevelEnabled then
        pumpSystem.tankLevel = io.readAnalog(io_map.tankLevel)
    end

    pumpSystem.signalStrength = wan.getRSSI()
end

function formatTankLevel()
    -- Convert analog reading to percentage (adjust scaling as needed)
    local percent = math.floor((pumpSystem.tankLevel / 5.0) * 100)
    if percent > 100 then percent = 100 end
    if percent < 0 then percent = 0 end
    return percent .. "%"
end

function formatRunTime()
    local hours = math.floor(runtime.totalSeconds / 3600)
    return hours .. "HRS"
end

function sendSms(phoneNumber, message)
    print("Sending SMS to " .. phoneNumber .. ": " .. message)
    wan.sendSMS(phoneNumber, message)
end

function sendAlert(message)
    if config.alertPhone ~= "" then
        sendSms(config.alertPhone, message)
    end
end

-- ============================================================================
-- MESSAGE FORMATTING
-- ============================================================================

function buildWeeklyReport()
    local msg = formatDateTime() .. "\n"
    msg = msg .. "NEO SIGNAL STRENGTH: " .. wan.getRSSI() .. "\n"
    msg = msg .. "NEO BATTERY VOLTAGE: " .. string.format("%.1f%", system.getBatteryPercent()) .. "\n"
    msg = msg .. "STATUS: " .. string.upper(state)
    if config.tankLevelEnabled then
        msg = msg .. "\nTANK LEVEL: " .. formatTankLevel()
    end
    return msg
end

function buildStartSuccessMessage()
    local msg = formatDateTime() .. "\n"
    msg = msg .. "FIRE SYSTEM RUNNING\n"
    msg = msg .. "STATUS: READY"
    return msg
end

function buildStartFailedMessage()
    local msg = formatDateTime() .. "\n"
    msg = msg .. "FIRE SYSTEM NOT RUNNING\n"
    msg = msg .. "MAX START ATTEMPTS REACHED\n"
    msg = msg .. "STATUS: FAULT"
    return msg
end

function buildStopMessage()
    local msg = formatDateTime() .. "\n"
    msg = msg .. "FIRE SYSTEM OFF\n"
    msg = msg .. "STATUS: READY"
    return msg
end

function buildLowVoltageMessage()
    local msg = formatDateTime() .. "\n"
    msg = msg .. "BATTERY VOLTAGE LOW\n"
    msg = msg .. "VOLTAGE: " .. string.format("%.1fV", pumpSystem.batteryVoltage) .. "\n"
    msg = msg .. "STATUS: ALARM"
    return msg
end

function buildVoltageNormalMessage()
    local msg = formatDateTime() .. "\n"
    msg = msg .. "BATTERY VOLTAGE RETURN TO NORMAL\n"
    msg = msg .. "STATUS: READY"
    return msg
end

function buildServiceMessage()
    local msg = formatDateTime() .. "\n"
    msg = msg .. "PUMP SERVICE REQUIRED\n"
    msg = msg .. "RUN TIME: " .. formatRunTime()
    return msg
end

-- ============================================================================
-- START PUMP LOGIC
-- ============================================================================

function initiateStart(phoneNumber)
    if state == "running" then
        sendSms(phoneNumber, "Pump is already running.")
        return
    end

    if state == "starting" then
        sendSms(phoneNumber, "Start sequence already in progress.")
        return
    end

    -- Send acknowledgment that command was received
    sendSms(phoneNumber, "START command received. Starting pump...")

    smsRequester = phoneNumber
    state = "starting"
    start.time = os.time()
    start.solenoidState = "cranking"
    start.attempt = 1
    start.confirmStartTime = 0

    print("Starting pump - Attempt " .. start.attempt)
    -- Turn on BOTH fuel solenoid and crank relay to start
    turnOn(io_map.fuelSolenoid)
    turnOn(io_map.crankRelay)
end

function processStartSequence()
    if state ~= "starting" then return end

    local now = os.time()

    if start.solenoidState == "cranking" then
        -- Crank for 5 seconds
        if now - start.time >= config.crankTime then
            -- Stop cranking but keep fuel solenoid on
            turnOff(io_map.crankRelay)
            start.solenoidState = "waitingConfirm"
            start.confirmStartTime = now
            print("Crank complete, waiting for pressure confirmation...")
        end

    elseif start.solenoidState == "waitingConfirm" then
        -- Check for pressure immediately - if found, start is successful
        if pumpSystem.pumpPressureSwitch then
            -- SUCCESS - fuel solenoid stays on, crank already off
            state = "running"
            start.solenoidState = "idle"
            runtime.sessionStart = now
            print("Pump started successfully!")

            if smsRequester ~= "" then
                sendSms(smsRequester, buildStartSuccessMessage())
            end
        -- Only retry if delay has passed and still no pressure
        elseif now - start.confirmStartTime >= config.pumpConfirmDelay then
            -- RETRY
            if start.attempt < config.maxStartAttempts then
                start.attempt = start.attempt + 1
                start.time = now
                start.solenoidState = "cranking"
                print("Start attempt " .. start.attempt)
                -- Fuel solenoid already on, turn crank back on
                turnOn(io_map.crankRelay)
            else
                -- FAILED after 3 attempts - turn everything off
                state = "failed"
                start.solenoidState = "idle"
                turnOff(io_map.fuelSolenoid)
                turnOff(io_map.crankRelay)
                print("Start FAILED after " .. config.maxStartAttempts .. " attempts")

                if smsRequester ~= "" then
                    sendSms(smsRequester, buildStartFailedMessage())
                end
                sendAlert(buildStartFailedMessage())
            end
        end
    end
end

-- ============================================================================
-- STOP PUMP LOGIC
-- ============================================================================

function initiateStop(phoneNumber)
    if state ~= "running" and state ~= "failed" then
        sendSms(phoneNumber, "Pump is not running.")
        return
    end

    -- Send acknowledgment that command was received
    sendSms(phoneNumber, "STOP command received. Stopping pump...")

    smsRequester = phoneNumber

    -- Update total runtime
    if runtime.sessionStart > 0 then
        runtime.totalSeconds = runtime.totalSeconds + (os.time() - runtime.sessionStart)
        runtime.sessionStart = 0
        saveRuntime()  -- Save to persistent storage
    end

    -- To stop: turn off BOTH fuel solenoid and crank relay
    turnOff(io_map.fuelSolenoid)
    turnOff(io_map.crankRelay)

    state = "idle"
    print("Pump stopped.")

    if smsRequester ~= "" then
        sendSms(smsRequester, buildStopMessage())
    end
end

-- ============================================================================
-- MONITORING FUNCTIONS
-- ============================================================================

function monitorBatteryVoltage()
    if pumpSystem.batteryVoltage < config.lowVoltageThreshold then
        if not alerts.lowVoltageAlerted then
            alerts.lowVoltageAlerted = true
            print("LOW BATTERY VOLTAGE: " .. pumpSystem.batteryVoltage .. "V")
            sendAlert(buildLowVoltageMessage())
        end
    elseif pumpSystem.batteryVoltage >= config.normalVoltageThreshold then
        if alerts.lowVoltageAlerted then
            alerts.lowVoltageAlerted = false
            print("Battery voltage returned to normal: " .. pumpSystem.batteryVoltage .. "V")
            sendAlert(buildVoltageNormalMessage())
        end
    end
end

function monitorRunTime()
    if state == "running" and runtime.sessionStart > 0 then
        local currentTotal = runtime.totalSeconds + (os.time() - runtime.sessionStart)
        local nextThreshold = runtime.lastServiceAlert + config.serviceInterval

        if currentTotal >= nextThreshold then
            runtime.lastServiceAlert = nextThreshold
            saveRuntime()  -- Save service alert milestone
            print("Service required - Run time: " .. formatRunTime())
            sendAlert(buildServiceMessage())
        end
    end
end

function checkWeeklyReport()
    local t = os.date("*t")
    local now = os.time()

    -- Check if it's Friday at 9 AM (within our update interval)
    if t.wday == config.weeklyReportDay and t.hour == config.weeklyReportHour then
        -- Only send once per hour window
        if now - alerts.lastWeeklyReport > 3600 then
            alerts.lastWeeklyReport = now
            print("Sending weekly report...")
            sendAlert(buildWeeklyReport())
        end
    end
end

-- ============================================================================
-- SMS POLLING
-- ============================================================================

function checkForSms()
    local now = os.time()
    if now - lastSmsCheck >= config.smsCheckInterval then
        lastSmsCheck = now
        wan.requestReadSMS()
    end
end

-- ============================================================================
-- SMS COMMAND HANDLING
-- ============================================================================

function handleSmsCommand(phoneNumber, command)
    print("Processing command: " .. command .. " from " .. phoneNumber)

    if command == "start" then
        initiateStart(phoneNumber)

    elseif command == "stop" then
        initiateStop(phoneNumber)

    elseif command == "status" then
        sendSms(phoneNumber, buildWeeklyReport())

    elseif command == "runtime" then
        local msg = formatDateTime() .. "\n"
        msg = msg .. "TOTAL RUN TIME: " .. formatRunTime()
        sendSms(phoneNumber, msg)

    elseif command == "reset" then
        -- Reset fault state
        if state == "failed" then
            state = "idle"
            start.attempt = 0
            sendSms(phoneNumber, "System reset. Status: READY")
        else
            sendSms(phoneNumber, "No fault to reset.")
        end

    elseif command == "clearhours" then
        -- Clear runtime hours (for pump replacement)
        clearRuntime()
        local msg = formatDateTime() .. "\n"
        msg = msg .. "RUN TIME CLEARED\n"
        msg = msg .. "PUMP REPLACED"
        sendSms(phoneNumber, msg)

    else
        print("Unknown command: " .. command)
        sendSms(phoneNumber, "Unknown command. Valid commands: START, STOP, STATUS, RUNTIME, RESET, CLEARHOURS")
    end
end

-- ============================================================================
-- CORE FUNCTIONS
-- ============================================================================

function core.setup()
    print("Fire Pump Control System Initializing...")
    io.writePowerOutput(io.SENSOR_POWER, io.HIGH)
    io.writePowerOutput(io.ACTUATOR_POWER, io.HIGH)

    -- Load saved runtime from persistent storage
    loadRuntime()

    -- Ensure all outputs are off at startup
    turnOff(io_map.crankRelay)
    turnOff(io_map.fuelSolenoid)

    -- Initialize last weekly report time
    alerts.lastWeeklyReport = os.time() - 3600

    -- SMS handler
    wan.onSMSReceived(function(phoneNumber, text)
        -- Normalize text to lower case and trim whitespace
        local command = string.match(string.lower(text), "^%s*(.-)%s*$")
        print("SMS received from " .. phoneNumber .. ": " .. text)
        handleSmsCommand(phoneNumber, command)
    end)

    print("System ready.")
end

function core.update()
    -- Update all sensor readings
    updateSystemStats()

    -- Check for incoming SMS every 30 seconds
    checkForSms()

    -- Process state machines
    processStartSequence()

    -- Ensure outputs are OFF when in failed or idle state
    if state == "failed" or state == "idle" then
        turnOff(io_map.crankRelay)
        turnOff(io_map.fuelSolenoid)
    end

    -- Monitoring
    monitorBatteryVoltage()
    monitorRunTime()
    checkWeeklyReport()
end

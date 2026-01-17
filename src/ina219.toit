// Copyright (C) 2025 Toit Contributors
// Use of this source code is governed by an MIT-style license that can be
// found in the package's LICENSE file.   See README.md.

import log
import binary
import serial.device as serial
import serial.registers as registers

/**
Toit Driver Library for an INA219 module, DC Shunt current and power sensor.

To use this library, consult the README.md and examples.
*/
class Ina219:
  /**
  Default $I2C-ADDRESS is 64 (0x40).  Valid addresses: 64 to 79.  See Datasheet.
  */
  static I2C-ADDRESS                            ::= 0x40

  /** 'Power Down' mode - used while configuring $set-measure-mode. */
  static MODE-POWER-DOWN           ::= 0b000
  /** Shunt voltage only in Triggered mode - used while configuring $set-measure-mode. */
  static MODE-SHUNT-TRIGGERED      ::= 0b001
  /** Bus voltage only in Triggered mode - used while configuring $set-measure-mode. */
  static MODE-BUS-TRIGGERED        ::= 0b010
  /** Shunt and bus voltage measurements in Triggered mode - used while configuring $set-measure-mode. */
  static MODE-SHUNT-BUS-TRIGGERED  ::= 0b011
  /** Shunt voltage only in Continuous mode - used while configuring $set-measure-mode. */
  static MODE-SHUNT-CONTINUOUS     ::= 0b101
  /** Bus voltage only in Continuous mode - used while configuring $set-measure-mode. */
  static MODE-BUS-CONTINUOUS       ::= 0b110
  /** Bus and Shunt voltage measured in Continuous mode - used while configuring $set-measure-mode. */
  static MODE-SHUNT-BUS-CONTINUOUS ::= 0b111

  // Core Register Addresses.
  static REG-CONFIG_         ::= 0x00  //RW  // All-register reset, settings for bus Configuration voltage range, PGA Gain, resolution/averaging
  static REG-SHUNT-VOLTAGE_  ::= 0x01  //R   // Shunt voltage measurement data.
  static REG-BUS-VOLTAGE_    ::= 0x02  //R   // Bus voltage measurement data.
  static REG-POWER_          ::= 0x03  //R   // Power measurement data.
  static REG-SHUNT-CURRENT_  ::= 0x04  //R   // Current measurement data.
  static REG-CALIBRATION_    ::= 0x05  //RW  // Calibration data.

  // Configuration Register bitmasks.
  static CONF-RESET-MASK_             ::= 0b10000000_00000000
  static CONF-BUS-VOLTAGE-RANGE-MASK_ ::= 0b00100000_00000000
  static CONF-SHUNT-VOLTAGE-PGA-MASK_ ::= 0b00011000_00000000
  static CONF-BUS-ADC-RES-AVG-MASK_   ::= 0b00000111_10000000
  static CONF-SHUNT-ADC-RES-AVG-MASK_ ::= 0b00000000_01111000
  static CONF-MODE-MASK_              ::= 0b00000000_00000111

  static SHUNT-VOLTAGE-PGA-G1-R40  ::= 0b00
  static SHUNT-VOLTAGE-PGA-G2-R80  ::= 0b01
  static SHUNT-VOLTAGE-PGA-G4-R160 ::= 0b10
  static SHUNT-VOLTAGE-PGA-G8-R320 ::= 0b11

  static BUS-VOLTAGE-MASK_ ::= 0b11111111_11111000
  static CONVERSION-READY_ ::= 0b00000000_00000010
  static OVERFLOW_         ::= 0b00000000_00000001

  static ADC-RES-AVG-M9-84      ::= 0b0000
  static ADC-RES-AVG-M10-148    ::= 0b0001
  static ADC-RES-AVG-M11-276    ::= 0b0010
  static ADC-RES-AVG-M12-532    ::= 0b0011
  static ADC-RES-AVG-M12-532-2  ::= 0b1000
  static ADC-RES-AVG-S2-1060    ::= 0b1001
  static ADC-RES-AVG-S4-2130    ::= 0b1010
  static ADC-RES-AVG-S8-4260    ::= 0b1011
  static ADC-RES-AVG-S16-8510   ::= 0b1100
  static ADC-RES-AVG-S32-17020  ::= 0b1101
  static ADC-RES-AVG-S64-34050  ::= 0b1110
  static ADC-RES-AVG-S128-68100 ::= 0b1111

  //static INTERNAL_SCALING_VALUE_/float         ::= 0.00512
  //static SHUNT-FULL-SCALE-VOLTAGE-LIMIT_/float ::= 0.08192    // volts.
  static SHUNT-VOLTAGE-LSB_      ::= 0.000010  // 10uV/bit
  static BUS-VOLTAGE-LSB_        ::= 0.004     // 4mV/bit
  static INTERNAL-SCALING-VALUE_ ::= 0.04096
  static POWER_LSB_MULTIPLIER_   ::= 20.0

  // Private variables.
  reg_/registers.Registers := ?
  logger_/log.Logger := ?
  shunt-resistor_/float := 0.0

  power-lsb_/float := 0.0
  current-lsb_/float := 0.0
  max-current_/float := 0.0

  constructor
      dev/serial.Device
      --shunt-resistor/float = 0.100
      --measure-mode = MODE-SHUNT-BUS-CONTINUOUS
      --force/bool = false                         // If is still INA219 despite POR Reset test
      --logger/log.Logger = log.default:
    logger_ = logger.with-name "ina219"
    reg_ = dev.registers
    shunt-resistor_ = shunt-resistor

    // Maybe not required but the manual suggests it should be done.
    // Also sets shunt resistor - and calibration value
    reset_

    // Initialize Default sampling, conversion timing, and measuring mode.
    set-shunt-adc-resolution-average ADC-RES-AVG-M12-532
    set-bus-adc-resolution-average ADC-RES-AVG-M12-532
    set-measure-mode measure-mode

    // Performing a single measurement during initialisation assists with accuracy for first reads.
    trigger-measurement --wait

  /**
  Resets the device.
  */
  reset_ -> none:
    last-measure-mode := get-measure-mode
    write-register_ REG-CONFIG_ 0b1 --mask=CONF-RESET-MASK_
    set-shunt-resistor_ shunt-resistor_
    set-measure-mode last-measure-mode

  /**
  Gets the current calibration value.

  The calibration value scales the raw sensor data so that it corresponds to
    real-world values, taking into account the shunt resistor value, the
    full-scale range, and other system-specific factors. This value is
    calculated automatically by the $set-shunt-resistor_ method - setting
    manually is not normally required, and is private.
  */
  get-calibration-value_ -> int:
    return read-register_ REG-CALIBRATION_
    //return reg_.read-u16-be REG-CALIBRATION_

  /**
  Sets calibration value.  See $get-calibration-value_.
  */
  set-calibration-value_ value/int -> none:
    write-register_ REG-CALIBRATION_ value

  /**
  Set shunt resolution/sampling rate combination for measurements.

  Note constraints about the use of this function. See README.md and Datasheet.
  */
  set-shunt-adc-resolution-average code/int -> none:
    write-register_ REG-CONFIG_ code --mask=CONF-SHUNT-ADC-RES-AVG-MASK_

  /**
  get shunt conversion time, in us, from the register and convert from the enum.

  To Do: Work out what to do if only shunt configured.
  */
  get-shunt-conversion-time-us_ -> int:
    raw := read-register_ REG-CONFIG_ --mask=CONF-SHUNT-ADC-RES-AVG-MASK_
    return get-conversion-time-us-enum raw

  /**
  get bus sampling-rate, in samples, from the register & convert from the enum.

  To Do: Work out what to do if only shunt configured.
  */
  get-shunt-sampling-rate_ -> int:
    raw := read-register_ REG-CONFIG_ --mask=CONF-SHUNT-ADC-RES-AVG-MASK_
    return get-sampling-rate-enum raw

 /**
  Set bus resolution/sampling rate combination for measurements.

  Note constraints about the use of this function. See README.md and Datasheet.
  */
  set-bus-adc-resolution-average code/int -> none:
    write-register_ REG-CONFIG_ code --mask=CONF-BUS-ADC-RES-AVG-MASK_

  /**
  get bus conversion time, in us, from the register & convert from the enum.
  */
  get-bus-conversion-time-us_ -> int:
    raw := read-register_ REG-CONFIG_ --mask=CONF-BUS-ADC-RES-AVG-MASK_
    return get-conversion-time-us-enum raw

  /**
  get bus sampling-rate, in samples, from the register & convert from the enum.
  */
  get-bus-sampling-rate_ -> int:
    raw := read-register_ REG-CONFIG_ --mask=CONF-BUS-ADC-RES-AVG-MASK_
    return get-sampling-rate-enum raw

  /**
  Sets Measure Mode.

  One of MODE-*** Options. See statics above, and the Datasheet.
  */
  set-measure-mode mode/int -> none:
    write-register_ REG-CONFIG_ mode --mask=CONF-MODE-MASK_

  /**
  Gets configured Measure Mode. See $set-measure-mode.
  */
  get-measure-mode -> int:
    return read-register_ REG-CONFIG_ --mask=CONF-MODE-MASK_

  /**
  Sets shunt voltage PGA Gain and PGA Range.

  One of SHUNT-VOLTAGE-PGA-** Options. See statics above, and the Datasheet.
  */
  set-shunt-voltage-pga-gain-range mode/int -> none:
    write-register_ REG-CONFIG_ mode --mask=CONF-SHUNT-VOLTAGE-PGA-MASK_

  get-shunt-voltage-pga-gain-range -> int:
    return read-register_ REG-CONFIG_ --mask=CONF-SHUNT-VOLTAGE-PGA-MASK_

  /**
  Gets shunt voltage PGA Gain for use in reads.
  */
  get-shunt-voltage-pga-gain_ -> int:
    raw := read-register_ REG-CONFIG_ --mask=CONF-SHUNT-VOLTAGE-PGA-MASK_
    return get-shunt-voltage-pga-gain-enum raw

  /**
  Gets shunt voltage PGA Range for use in reads.
  */
  get-shunt-voltage-pga-range_ -> int:
    raw := read-register_ REG-CONFIG_ --mask=CONF-SHUNT-VOLTAGE-PGA-MASK_
    return get-shunt-voltage-pga-range-enum raw

  /**
  Set bus voltage full scale range.  Either 16v or 32v.

  Note constraints about the use of this function. See README.md and Datasheet.
  */
  set-bus-voltage-fs-range voltage/int -> none:
    assert: (voltage == 16) or (voltage == 32)
    if voltage == 16: write-register_ REG-CONFIG_ 0 --mask=CONF-BUS-VOLTAGE-RANGE-MASK_
    if voltage == 32: write-register_ REG-CONFIG_ 1 --mask=CONF-BUS-VOLTAGE-RANGE-MASK_

  get-bus-voltage-fs-range -> float:
    raw := read-register_ REG-CONFIG_ --mask=CONF-BUS-VOLTAGE-RANGE-MASK_
    if raw == 1: return 32.0
    else: return 16.0

  /**
  Sets the resistor and current range.  See README.md
  */
  set-shunt-resistor_ resistor/float --max-current=((get-shunt-voltage-pga-range_.to-float / 1000.0) / resistor) -> none:
    // Cache to class-wide for later use.
    shunt-resistor_ = resistor
    // Cache to class-wide for later use.
    max_current_ = max-current
    // Cache LSB of max current selection (amps per bit).
    current-lsb_ = max-current_ / 32767.0
    // Calculate new calibration value and set in the IC
    new-calibration-value/int := (INTERNAL_SCALING_VALUE_ / (current-lsb_ * resistor)).round
    set-calibration-value_ (clamp-value_ new-calibration-value --lower=1 --upper=0xFFFF)
    // Cache new power multiplier/LSB
    power-lsb_   = POWER_LSB_MULTIPLIER_ * current-lsb_

  /**
  Returns upstream voltage, before the shunt (IN+).

  This is the rail straight from the power source, minus any drop across the
   shunt. Since INA219 doesn’t have a dedicated pin for this, it can be
   reconstructed by: Vsupply = Vbus + Vshunt.  i.e. adding the measured bus
   voltage (load side) and the measured shunt voltage.
  */
  read-supply-voltage -> float:
    return read-bus-voltage + read-shunt-voltage

  /**
  Returns shunt voltage in volts.

  The shunt voltage is the voltage drop across the shunt resistor, which allows
   the IC to calculate current. The IC measures this voltage to calculate the
   current flowing through the load.
  */
  read-shunt-voltage -> float:
    raw := read-register_ REG-SHUNT-VOLTAGE_ --signed
    return raw * SHUNT-VOLTAGE-LSB_

  /**
  Return voltage of whatever is wired to the VBUS pin.

  On most breakout boards, VBUS is tied internally to IN− (the low side of the
   shunt). So in practice, “bus voltage” usually means the voltage at the load
   side of the shunt.  This is what the load actually sees as its supply rail.
   The voltage should not be modified based on BRNG - it sets the highest value
   the register will go, independent of the register's max values.
  */
  read-bus-voltage -> float:
    value := read-register_ REG-BUS-VOLTAGE_ --mask=BUS-VOLTAGE-MASK_
    return value * BUS-VOLTAGE-LSB_

  /**
  Returns shunt current in amps.
  */
  read-shunt-current -> float:
    value   := reg_.read-i16-be REG-SHUNT-CURRENT_
    return value * current-lsb_

  /**
  Returns power used by the load in watts.
  */
  read-load-power -> float:
    value := reg_.read-u16-be REG-POWER_
    return (value * power-lsb_).to-float

  /**
  Waits for 'conversion-ready', with a maximum wait of $get-estimated-conversion-time-ms.
  */
  wait-until-conversion-completed --max-wait-time-ms/int=(get-estimated-conversion-time-ms) -> none:
    current-wait-time-ms/int := 0
    sleep-interval-ms/int := (max-wait-time-ms / 10)
    while (not is-conversion-ready):
      sleep --ms=sleep-interval-ms
      current-wait-time-ms += sleep-interval-ms
      if current-wait-time-ms >= max-wait-time-ms:
        logger_.debug "wait-until-conversion-completed: max-wait-time exceeded - continuing"
          --tags={ "max-wait-time-ms" : max-wait-time-ms }
        break
    clear-conversion-ready

  /**
  Performs a single conversion/measurement.

  If in $MODE_TRIGGERED:  Executes one measurement.
  If in $MODE_CONTINUOUS: Immediately refreshes data.

  If $wait is set, waits until the conversion is done. By default $wait is
   true if in $MODE-TRIGGERED.
  */
  /**
  Perform a single conversion/measurement - without waiting.

  If in any TRIGGERED mode:  Executes one measurement.
  If in any CONTINUOUS mode: Immediately refreshes data.
  */
  trigger-measurement --wait/bool=false -> none:
    // Clear conversion ready so waiting works.
    clear-conversion-ready

    // If in triggered mode, wait by default.
    should-wait/bool := false
    current-measure-mode := get-measure-mode
    if current-measure-mode == MODE-SHUNT-TRIGGERED: should-wait = true
    if current-measure-mode == MODE-BUS-TRIGGERED: should-wait = true
    if current-measure-mode == MODE-SHUNT-BUS-TRIGGERED: should-wait = true

    // Rewriting the mode bits starts a conversion.
    set-measure-mode current-measure-mode

    // Wait if required. If in triggered mode, wait by default, respect switch.
    if should-wait or wait: wait-until-conversion-completed

  /**
  Returns whether a conversion is complete.

  Although the device can be read at any time, and the data from the last
   conversion is available, the 'Conversion Ready Flag' bit is provided to help
   coordinate one-shot or triggered conversions.  The Conversion Ready Flag bit
   is set after all conversions, averaging, and multiplications are complete,
   and this function returns the value of this bit.

   It clears under the following conditions:
    1. Writing to the Configuration Register (except when Power-Down).
    2. Reading the Power Register (Implemented in $clear-conversion-ready).
  */
  is-conversion-ready -> bool:
    raw/int := read-register_ REG-BUS-VOLTAGE_ --mask=CONVERSION-READY_
    return raw == 1

  clear-conversion-ready -> none:
    raw := read-register_ REG-POWER_

  /**
  Whether a math overflow exists.  (Reading consumes it.)
  */
  is-alert-overflow  -> bool:
    raw/int := read-register_ REG-BUS-VOLTAGE_ --mask=OVERFLOW_
    clear-conversion-ready
    return raw == 1

  /**
  Returns gain value (1,2,4 or 8) from combined SHUNT-VOLTAGE-PGA-* values.
  */
  get-shunt-voltage-pga-gain-enum code/int -> int:
    if code == SHUNT-VOLTAGE-PGA-G1-R40 : return 1
    if code == SHUNT-VOLTAGE-PGA-G2-R80 : return 2
    if code == SHUNT-VOLTAGE-PGA-G4-R160 : return 4
    if code == SHUNT-VOLTAGE-PGA-G8-R320 : return 8
    logger_.error "get-shunt-voltage-pga-gain: unexpected value" --tags={ "value" : code }
    return 8 // Default / Defensive

  /**
  Returns mv range value (40, 80, 160 or 320) from combined SHUNT-VOLTAGE-PGA-* values.
  */
  get-shunt-voltage-pga-range-enum code/int -> int:
    if code == SHUNT-VOLTAGE-PGA-G1-R40 : return 40
    if code == SHUNT-VOLTAGE-PGA-G2-R80 : return 80
    if code == SHUNT-VOLTAGE-PGA-G4-R160 : return 160
    if code == SHUNT-VOLTAGE-PGA-G8-R320 : return 320
    logger_.error "get-shunt-voltage-pga-range: unexpected value" --tags={ "value" : code }
    return 320 // Default / Defensive

  /**
  Returns conversion time (us) for combined SHUNT-ADC-RES-AVG-* resolution values.
  */
  get-conversion-time-us-enum code/int -> int:
    if code == ADC-RES-AVG-M9-84: return 84
    if code == ADC-RES-AVG-M10-148: return 148
    if code == ADC-RES-AVG-M11-276: return 276
    if code == ADC-RES-AVG-M12-532: return 532
    if code == ADC-RES-AVG-M12-532-2: return 532
    if code == ADC-RES-AVG-S2-1060: return 1060
    if code == ADC-RES-AVG-S4-2130: return 2130
    if code == ADC-RES-AVG-S8-4260: return 4260
    if code == ADC-RES-AVG-S16-8510: return 8510
    if code == ADC-RES-AVG-S32-17020: return 17020
    if code == ADC-RES-AVG-S64-34050: return 34050
    if code == ADC-RES-AVG-S128-68100: return 68100
    logger_.error "get-conversion-time-us-from-enum: unexpected value" --tags={ "value" : code }
    return 68100  // default/defensive - should never happen

  /**
  Returns sampling count for combined SHUNT-ADC-RES-AVG-* resolution values.
  */
  get-sampling-rate-enum code/int -> int:
    if code == ADC-RES-AVG-M9-84: return 1
    if code == ADC-RES-AVG-M10-148: return 1
    if code == ADC-RES-AVG-M11-276: return 1
    if code == ADC-RES-AVG-M12-532: return 1
    if code == ADC-RES-AVG-M12-532-2: return 1
    if code == ADC-RES-AVG-S2-1060: return 2
    if code == ADC-RES-AVG-S4-2130: return 4
    if code == ADC-RES-AVG-S8-4260: return 8
    if code == ADC-RES-AVG-S16-8510: return 16
    if code == ADC-RES-AVG-S32-17020: return 32
    if code == ADC-RES-AVG-S64-34050: return 64
    if code == ADC-RES-AVG-S128-68100: return 128
    logger_.error "get-sampling-rate-from-enum: unexpected value" --tags={ "value" : code }
    return 1  // default/defensive - should never happen

  /**
  Returns reduced mask for combined SHUNT-ADC-RES-AVG-* resolution values.
  */
  get-adc-mask-from-enum code/int -> int:
    if code == ADC-RES-AVG-M9-84: return 9
    if code == ADC-RES-AVG-M10-148: return 10
    if code == ADC-RES-AVG-M11-276: return 11
    // All other options return 12.
    return 12

  /**
  Estimates a worst-case maximum waiting time (+10%) based on the configuration.

  Done this way to prevent setting a max-wait type value of the worst case
   situation for all situations.
  */
  get-estimated-conversion-time-ms -> int:
    // given time and samples are already together, assuming time is that
    // required for the indicated samples.

    total-us/int := 0
    if should-include_ --bus:
      total-us += get-bus-conversion-time-us_
    if should-include_ --shunt:
      total-us += get-shunt-conversion-time-us_

    // Add a small guard factor (~10%) to be conservative.
    total-us = ((total-us * 11.0) / 10.0).round

    // Return milliseconds, minimum 1 ms
    total-ms := ((total-us + 999) / 1000)  // Ceiling.
    if total-ms < 1: total-ms = 1

    //logger_.debug "get-estimated-conversion-time-ms:"  --tags={ "get-estimated-conversion-time-ms" : total-ms }
    return total-ms

  /**
  Helper to know if bus or shunt modes are configured.
  */
  should-include_ --bus=false --shunt=false -> bool:
    mode := get-measure-mode
    if shunt and ((mode == MODE-SHUNT-TRIGGERED) or (mode == MODE-SHUNT-CONTINUOUS)):
      return true
    if bus and ((mode == MODE-BUS-TRIGGERED) or (mode == MODE-BUS-CONTINUOUS)):
      return true
    if (shunt or bus) and ((mode == MODE-SHUNT-BUS-CONTINUOUS) or (mode == MODE-SHUNT-BUS-TRIGGERED)):
      return true
    return false

  /**
  Reads the given register with the supplied mask.

  All INA219 registers are big-endian. If the mask is left at 0xFFFF and offset
   at 0x0, it is treated as a read from the whole register.
  */
  read-register_ register --mask=0xFFFF --offset=(mask.count-trailing-zeros) --signed=false -> any:
    raw-value := ?
    if signed:
      raw-value = reg_.read-i16-be register
    else:
      raw-value = reg_.read-u16-be register

    if mask == 0xFFFF and offset == 0:
      //logger_.debug "read-register_:" --tags={ "register" : register , "register-value" : raw-value }
      return raw-value
    else:
      masked-value := (raw-value & mask) >> offset
      //logger_.debug "read-register_:"  --tags={ "register" : register , "register-value" : raw-value, "mask" : mask , "offset" : offset}
      return masked-value

  /**
  Writes the given register with the supplied mask.

  Given that register writes are largely similar, it is implemented here.  All
   INA219 registers are big-endian. If the mask is left at 0xFFFF and offset at
   0x0, it is treated as a write to the whole register.
  */
  write-register_ register/int value/any --mask/int=0xFFFF --offset/int=(mask.count-trailing-zeros) -> none:
    // find allowed value range within field
    max/int := mask >> offset
    // check the value fits the field
    assert: ((value & ~max) == 0)

    if (mask == 0xFFFF) and (offset == 0):
      reg_.write-u16-be register (value & 0xFFFF)
    else:
      new-value/int := reg_.read-u16-be register
      new-value     &= ~mask
      new-value     |= (value << offset)
      reg_.write-u16-be register new-value

  /**
  Clamps the supplied value to specified limit.
  */
  clamp-value_ value/any --upper/any?=null --lower/any?=null -> any:
    if upper != null: if value > upper:  return upper
    if lower != null: if value < lower:  return lower
    return value

  /**
  Print Diagnostic Information.

  Prints relevant measurement information allowing someone with a Voltmeter to
   double check what is measured and compare it.  Also tries to self-check a
   little by calculating/comparing using Ohms Law (V=I*R).
  */
  print-diagnostics -> none:
    // Optional: ensure fresh data.
    trigger-measurement --wait
    wait-until-conversion-completed

    shunt-voltage/float                := read-shunt-voltage
    load-voltage/float                 := read-bus-voltage                   // what the load actually sees (Vbus, eg IN−).
    supply-voltage/float               := load-voltage + shunt-voltage       // upstream rail (IN+ = IN− + Vshunt).
    shunt-voltage-delta/float          := supply-voltage - load-voltage      // same as Vshunt.
    shunt-voltage-delta-percent/float  := 0.0
    if supply-voltage > 0.0: shunt-voltage-delta-percent = (shunt-voltage-delta / supply-voltage) * 100.0

    calibration-value/int              := get-calibration-value_
    current-raw/int                    := reg_.read-i16-be REG-SHUNT-CURRENT_
    least-significant-bit/float        := INTERNAL-SCALING-VALUE_ / (calibration-value.to-float * shunt-resistor_)
    current-chip/float                 := current-raw * least-significant-bit
    current-v-r/float                  := shunt-voltage / shunt-resistor_

    // CROSSCHECK: between chip/measured current and V/R reconstructed current.
    current-difference/float           := (current-chip - current-v-r).abs
    current-difference-percent/float   := 0.0
    if (current-v-r != 0.0):
      current-difference-percent       = (current-difference / current-v-r) * 100.0

    // CROSSCHECK: shunt voltage (measured vs reconstructed).
    shunt-voltage-calculated/float          := current-chip * shunt-resistor_
    shunt-voltage-difference/float          := (shunt-voltage - shunt-voltage-calculated).abs
    shunt-voltage-difference-percent/float  := 0.0
    if (shunt-voltage != 0.0):
      shunt-voltage-difference-percent      = (shunt-voltage-difference / shunt-voltage).abs * 100.0

    print "DIAG :"
    print "    ----------------------------------------------------------"
    print "    Shunt Resistor      =  $(%0.8f shunt-resistor_) Ohm (Configured in code)"
    print "    Vload    (IN-)      =  $(%0.8f load-voltage)  V"
    print "    Vsupply  (IN+)      =  $(%0.8f supply-voltage)  V"
    print "    Shunt Voltage delta =  $(%0.8f shunt-voltage-delta)  V"
    print "                        = ($(%0.8f shunt-voltage-delta*1000.0)  mV)"
    print "                        = ($(%0.3f shunt-voltage-delta-percent)% of supply)"
    print "    Vshunt (direct)     =  $(%0.8f shunt-voltage)  V"
    print "    ----------------------------------------------------------"
    print "    Calibration Value   =  $(calibration-value)"
    print "    I (raw register)    = ($(current-raw))"
    print "                 LSB    = ($(%0.8f least-significant-bit)  A/LSB)"
    print "    I (from module)     =  $(%0.8f current-chip)  A"
    print "    I (from V/R)        =  $(%0.8f current-v-r)  A"
    print "    ----------------------------------------------------------"
    if current-difference-percent < 5.0:
      print "    Check Current       : OK - Currents agree ($(%0.3f current-difference-percent)% under/within 5%)"
    else if current-difference-percent < 20.0:
      print "    Check Current       : WARNING (5% < $(%0.3f current-difference-percent)% < 20%) - differ noticeably"
    else:
      print "    Check Current       : BAD!! ($(%0.3f current-difference-percent)% > 20%): check calibration or shunt value"
    if shunt-voltage-difference-percent < 5.0:
      print "    Check Shunt Voltage : OK - Shunt voltages agree ($(%0.3f shunt-voltage-difference-percent)% under/within 5%)"
    else if shunt-voltage-difference-percent < 20.0:
      print "    Check Shunt Voltage : WARNING (5% < $(%0.3f shunt-voltage-difference-percent)% < 20%) - differ noticeably"
    else:
      print "    Check Shunt Voltage : BAD!! ($(%0.3f shunt-voltage-difference-percent)% > 20%): shunt voltage mismatch"

  /**
  Provides strings to display bitmasks nicely when testing.
  */
  bits-16_ x/int --min-display-bits/int=0 -> string:
    if (x > 255) or (min-display-bits > 8):
      out-string := "$(%b x)"
      out-string = out-string.pad --left 16 '0'
      out-string = "$(out-string[0..4]).$(out-string[4..8]).$(out-string[8..12]).$(out-string[12..16])"
      return out-string
    else if (x > 15) or (min-display-bits > 4):
      out-string := "$(%b x)"
      out-string = out-string.pad --left 8 '0'
      out-string = "$(out-string[0..4]).$(out-string[4..8])"
      return out-string
    else:
      out-string := "$(%b x)"
      out-string = out-string.pad --left 4 '0'
      out-string = "$(out-string[0..4])"
      return out-string

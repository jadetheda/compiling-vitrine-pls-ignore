# Reverb Acoustic Evaluation & Options

## Problem Statement
Users reported that the reverb audio effect sounded "painful and tinny" across all playback presets and sliders. 

## Root Cause Analysis
An acoustic and DSP analysis of `tweak/Sources/Shared/AudioEffects/SGDSPReverb.m` and Apple's `AUReverb2` (`kAudioUnitSubType_Reverb2`) revealed three compounding root causes:

1. **Severe Early Reflection Comb Filtering (`minDelay` too short)**
   - Previous settings used reflection delay minimums as short as **0.001s (1 ms)** for Plate and **0.002s (2 ms)** for Ambience.
   - Delay offsets under 5 ms superimpose delayed copies onto the direct signal inside the Haas window, causing static comb-filtering notches and resonant peaks directly in the human ear's most sensitive hearing spectrum (1 kHz – 5 kHz). This creates the hollow, metallic "tin can" coloration.

2. **Underdamped High-Frequency Decay (`decayHigh` / `DecayTimeAtNyquist`)**
   - In physical acoustics, high frequencies are heavily attenuated by atmospheric viscosity and boundary absorption (air damping).
   - In the previous preset table, Nyquist decay times were almost identical to base 0 Hz decay (e.g. Plate had `decay = 1.80s` and `decayHigh = 1.60s`, an 89% high-frequency retention; Chamber had `0.90s` high decay).
   - This caused vocal sibilants ("s", "t", "ch") and cymbal transients to ring out indefinitely with a sharp, piercing sizzle.

3. **Low Reflection Diffusion (`density` / `RandomizeReflections`)**
   - The density parameter was set to only 400 (and 600–800 for select presets), out of a maximum of 1000.
   - Low randomization creates discrete flutter echoes and periodic modal ringing along the delay taps instead of a continuous, smooth diffuse field.

4. **Excessive Wet Mix Ratio at Normal Slider Values**
   - The preset mix scalars reached up to 30, meaning a 100% slider value generated up to 60% wet signal, overwhelming the direct mix.

---

## Architectural Options Evaluated

### Option 1: Calibrated Acoustic Profile on Native `AUReverb2` (Implemented)
- **Design:**
  - Increase `minDelay` to a natural acoustic range (**8 ms to 35 ms**). Early reflections no longer destructive comb-filter the direct signal.
  - Implement realistic air absorption by steepening high-frequency decay (**`decayHigh` damped to 0.08s – 0.32s**). Reverb tails decay warmly from the top down, eliminating sibilance ringing.
  - Maximize reflection randomization (**`density = 1000`**) across all presets to disperse modal clusters into silky, smooth diffusion.
  - Calibrate the mix range (8% to 25% base mix) so slider adjustment remains musical and usable across the entire 0–100% range.
- **Pros:**
  - Zero added memory or CPU overhead.
  - Zero allocation on the render thread (preserves strict CoreAudio real-time guarantees).
  - Compatible with Apple hardware acceleration.
- **Cons:**
  - Relies on Apple's AUReverb2 internal algorithmic topology.

### Option 2: Post-Reverb One-Pole Low-Pass Filter on Wet Bus
- **Design:**
  - Run AUReverb2 100% wet in an auxiliary buffer, apply a 6 dB/octave low-pass filter at ~6.5 kHz, and sum with dry audio.
- **Evaluation:**
  - While flexible, Option 1's native `kReverb2Param_DecayTimeAtNyquist` already performs frequency-dependent damping throughout the recursive delay network rather than merely dulling the final output. Option 1 sounds more three-dimensional without requiring secondary buffer copies.

### Option 3: Convolution Reverb via `SGDSPConvolver`
- **Design:**
  - Replace algorithmic reverb with impulse responses from high-end hardware units (Lexicon 480L, Bricasti M7).
- **Evaluation:**
  - Vitrine already has an optimized partition-convolver (`SGDSPConvolver.m`) used for headphone AutoEq and impulse responses. However, IR convolution requires significant memory and CPU power for long tails (>2 seconds) and cannot dynamically adjust room size or decay smoothly in real-time like AUReverb2 does with the player slider.

---

## Comparison Table

| Preset | Old `minDelay` | Tuned `minDelay` | Old `decayHigh` | Tuned `decayHigh` | Old `density` | Tuned `density` | Acoustic Result |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Ambience** | 2 ms | 8 ms | 0.20 s | 0.08 s | 400 | 1000 | Transparent air, zero comb notches |
| **Small Room** | 4 ms | 10 ms | 0.30 s | 0.12 s | 400 | 1000 | Warm wood/drywall room, no metallic buzz |
| **Medium Room** | 6 ms | 14 ms | 0.50 s | 0.18 s | 400 | 1000 | Balanced studio live room |
| **Large Room** | 8 ms | 18 ms | 0.75 s | 0.22 s | 400 | 1000 | Spacious acoustic bloom, clean vocals |
| **Chamber** | 5 ms | 12 ms | 0.90 s | 0.20 s | 600 | 1000 | Classic diffuse stone chamber |
| **Plate** | 1 ms | 8 ms | 1.60 s | 0.30 s | 800 | 1000 | Smooth studio plate, no sheet-metal ringing |
| **Small Hall** | 12 ms | 22 ms | 1.00 s | 0.25 s | 400 | 1000 | Natural symphonic hall |
| **Large Hall** | 20 ms | 28 ms | 1.60 s | 0.28 s | 400 | 1000 | Deep, lush hall with soft decay |
| **Cathedral** | 30 ms | 35 ms | 3.00 s | 0.32 s | 400 | 1000 | Cavernous sacred space, controlled highs |

To find the BPM (beats per minute) of a piece of music using wavelets, an algorithm typically involves these key steps:

Preprocessing the Audio Signal: Load the audio and possibly convert it to a mono signal. Normalize or filter to focus on rhythmic elements (e.g., percussive sounds).

Wavelet Transform Application: Apply a discrete wavelet transform (DWT) to the audio signal. The wavelet transform decomposes the signal into components at different frequency bands and time resolutions, capturing transient, rhythmic features effectively.

Feature Extraction from Wavelet Coefficients: Sum or combine relevant wavelet detail coefficients across levels to emphasize rhythmic peaks matching beat events.

Autocorrelation or Periodicity Analysis: Compute the autocorrelation function on the combined wavelet representation to detect periodicities corresponding to the tempo. Peaks in autocorrelation represent likely beat intervals.

Tempo Estimation: Identify the lag corresponding to the highest autocorrelation peak (excluding zero lag) to estimate the main beat period. Convert this lag to BPM by accounting for the sampling rate of the signal.

Post-Processing: Optionally refine or verify the estimated BPM by comparing multiple scales or filtering out implausible tempo ranges.

This approach leverages the multi-scale time-frequency localization ability of wavelets to reveal rhythmic structures better than straightforward Fourier analysis for non-stationary music signals. The discrete wavelet transform offers a computationally efficient means to isolate beats and estimate tempo through periodicity analysis of wavelet coefficients.

This is the essence of BPM detection algorithms that use wavelets as described in the literature and implementations such as the one by Tzanetakis et al. (2001) "Audio Analysis using the Discrete Wavelet Transform" 
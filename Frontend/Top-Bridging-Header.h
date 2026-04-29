//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//

#include <Foundation/Foundation.h>
#include <math.h>

// Fast integer to string conversion
static inline int fastItoa(int value, char* buffer, int bufferSize) {
    if (bufferSize < 2) return 0;

    int isNegative = 0;
    if (value < 0) {
        isNegative = 1;
        value = -value;
    }

    // Convert digits in reverse
    char temp[32];
    int i = 0;
    if (value == 0) {
        temp[i++] = '0';
    } else {
        while (value > 0 && i < 31) {
            temp[i++] = '0' + (value % 10);
            value /= 10;
        }
    }

    // Add negative sign if needed
    int pos = 0;
    if (isNegative && pos < bufferSize - 1) {
        buffer[pos++] = '-';
    }

    // Copy digits in correct order
    while (i > 0 && pos < bufferSize - 1) {
        buffer[pos++] = temp[--i];
    }

    buffer[pos] = '\0';
    return pos;
}

static inline int fastItoa64(long long value, char* buffer, size_t bufferSize) {
    if (bufferSize < 2) return 0;

    int isNegative = 0;
    unsigned long long absValue;
    if (value < 0) {
        isNegative = 1;
        absValue = (unsigned long long)(-(value + 1)) + 1; // Avoid overflow for LLONG_MIN
    } else {
        absValue = (unsigned long long)value;
    }

    char temp[32];
    int i = 0;
    if (absValue == 0) {
        temp[i++] = '0';
    } else {
        while (absValue > 0 && i < 31) {
            temp[i++] = '0' + (absValue % 10);
            absValue /= 10;
        }
    }

    int pos = 0;
    if (isNegative && pos < bufferSize - 1) {
        buffer[pos++] = '-';
    }

    while (i > 0 && pos < bufferSize - 1) {
        buffer[pos++] = temp[--i];
    }

    buffer[pos] = '\0';
    return pos;
}

// Fast number formatting without sprintf
static inline int formatNumberFast(float d, char* output, size_t outputSize) {
    if (outputSize < 2) return 0;

    float absVal = fabsf(d);
    int pos = 0;

    // Handle negative sign
    if (d < 0 && pos < outputSize - 1) {
        output[pos++] = '-';
    }

    if (absVal >= 10.0f) {
        // Round to nearest integer
        int rounded = (int)roundf(absVal);
        char temp[32];
        int len = fastItoa(rounded, temp, 32);

        // Copy to output
        for (int i = 0; i < len && pos < outputSize - 1; i++) {
            output[pos++] = temp[i];
        }
    }
    else if (absVal >= 1.0f) {
        // One decimal place: multiply by 10, round, then insert decimal
        int scaledValue = (int)roundf(absVal * 10.0f);
        int wholePart = scaledValue / 10;
        int fracPart = scaledValue % 10;

        // Check if rounding caused us to go to 10 or higher
        if (wholePart >= 10) {
            // Just output as integer
            char temp[32];
            int len = fastItoa(wholePart, temp, 32);
            for (int i = 0; i < len && pos < outputSize - 1; i++) {
                output[pos++] = temp[i];
            }
        } else {
            // Write whole part (single digit)
            if (wholePart > 0) {
                output[pos++] = '0' + wholePart;
            }

            // Write decimal point and fractional part
            if (pos < outputSize - 2) {
                output[pos++] = '.';
                output[pos++] = '0' + fracPart;
            }
        }
    }
    else if (absVal > 0.0f && absVal < 1.0f) {
        // Two significant figures for all numbers less than 1
        // Find the position of the first significant digit
        int exponent = (int)floorf(log10f(absVal));  // Will be negative (e.g., -1 for 0.5, -2 for 0.05)

        // Scale to get exactly 2 significant digits as an integer
        float scale = powf(10.0f, -exponent + 1);
        int twoDigits = (int)roundf(absVal * scale);

        // Ensure we have exactly 2 digits (handle edge cases)
        if (twoDigits >= 100) twoDigits = 99;
        if (twoDigits < 10) twoDigits *= 10;  // This shouldn't happen with proper rounding

        // Write "0."
        if (pos < outputSize - 2) {
            output[pos++] = '0';
            output[pos++] = '.';
        }

        // Add leading zeros if needed (for numbers like 0.0034)
        // If exponent is -2 or less, we need leading zeros
        for (int i = -1; i > exponent && pos < outputSize - 1; i--) {
            output[pos++] = '0';
        }

        // Write the two significant digits
        if (pos < outputSize - 2) {
            output[pos++] = '0' + (twoDigits / 10);
            output[pos++] = '0' + (twoDigits % 10);
        }
    }
    else {
        // Handle zero
        if (pos < outputSize - 1) {
            output[pos++] = '0';
        }
    }

    output[pos] = '\0';
    return pos;
}

static inline int formatNumberSingleDecimalFast(float value, char* output, size_t outputSize) {
    if (outputSize < 4) return 0;

    int pos = 0;
    float absValue = fabsf(value);
    int scaled = (int)roundf(absValue * 10.0f);
    int integerPart = scaled / 10;
    int fractionalPart = scaled % 10;

    if (value < 0 && pos < (int)outputSize - 1) {
        output[pos++] = '-';
    }

    char temp[32];
    int integerLength = fastItoa(integerPart, temp, 32);
    for (int i = 0; i < integerLength && pos < (int)outputSize - 1; i++) {
        output[pos++] = temp[i];
    }

    if (pos >= (int)outputSize - 2) {
        output[outputSize - 1] = '\0';
        return (int)outputSize - 1;
    }

    output[pos++] = '.';
    output[pos++] = '0' + fractionalPart;
    output[pos] = '\0';
    return pos;
}

static inline int formatNumberWithFractionDigitsFast(double value, int fractionalDigits, char* output, size_t outputSize) {
    if (outputSize < 2) return 0;
    if (fractionalDigits < 0 || fractionalDigits > 6) return 0;

    if (!isfinite(value) || value < 0) {
        value = 0;
    }

    long long multiplier = 1;
    for (int i = 0; i < fractionalDigits; i++) {
        multiplier *= 10;
    }

    long long scaled = llround(value * (double)multiplier);
    long long whole = scaled;
    long long fractional = 0;

    if (fractionalDigits > 0) {
        whole = scaled / multiplier;
        fractional = scaled % multiplier;
    }

    int pos = fastItoa64(whole, output, outputSize);
    if (pos <= 0) return pos;

    if (fractionalDigits == 0) {
        return pos;
    }

    if (pos + fractionalDigits + 1 >= (int)outputSize) return 0;

    output[pos++] = '.';

    long long divisor = 1;
    for (int i = 1; i < fractionalDigits; i++) {
        divisor *= 10;
    }

    for (int i = 0; i < fractionalDigits; i++) {
        int digit = (int)(fractional / divisor);
        output[pos++] = (char)('0' + digit);
        fractional -= digit * divisor;
        if (divisor > 1) {
            divisor /= 10;
        }
    }

    output[pos] = '\0';
    return pos;
}

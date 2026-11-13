package kzs.th000.tsdm_client

import android.content.res.Configuration
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** The keyboard shortcuts on Android follow the configuration's keyboard, never the key events. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 35], manifest = Config.NONE)
class HardwareKeyboardsTest {
    private fun config(keyboard: Int, hidden: Int) = Configuration().apply {
        this.keyboard = keyboard
        hardKeyboardHidden = hidden
    }

    @Test fun attachedFullKeyboard() {
        assertTrue(HardwareKeyboards.inUse(config(Configuration.KEYBOARD_QWERTY, Configuration.HARDKEYBOARDHIDDEN_NO)))
    }

    @Test fun phoneWithoutKeyboard() {
        assertFalse(HardwareKeyboards.inUse(config(Configuration.KEYBOARD_NOKEYS, Configuration.HARDKEYBOARDHIDDEN_YES)))
        assertFalse(HardwareKeyboards.inUse(config(Configuration.KEYBOARD_NOKEYS, Configuration.HARDKEYBOARDHIDDEN_NO)))
        assertFalse(HardwareKeyboards.inUse(config(Configuration.KEYBOARD_UNDEFINED, Configuration.HARDKEYBOARDHIDDEN_UNDEFINED)))
    }

    @Test fun hiddenKeyboard() {
        assertFalse(HardwareKeyboards.inUse(config(Configuration.KEYBOARD_QWERTY, Configuration.HARDKEYBOARDHIDDEN_YES)))
    }

    @Test fun twelveKeyPadTypesNoShortcut() {
        assertFalse(HardwareKeyboards.inUse(config(Configuration.KEYBOARD_12KEY, Configuration.HARDKEYBOARDHIDDEN_NO)))
    }
}

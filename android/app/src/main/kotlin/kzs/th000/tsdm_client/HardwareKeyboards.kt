package kzs.th000.tsdm_client

import android.content.res.Configuration

/**
 * Whether a hardware keyboard is in use, for the keyboard shortcuts of the app (`HardwareKeyboardPresence` in Dart).
 *
 * Dart cannot tell from the key events: the input methods send some keys (delete, enter) as key events of a keyboard
 * source, and the volume and back keys come as key events too. The configuration tells it: a full keyboard
 * ([Configuration.KEYBOARD_QWERTY]; a phone's twelve keys type no shortcut) that is not hidden (a slide-out keyboard
 * pushed in, a cover keyboard folded back). The activity handles the `keyboard|keyboardHidden` configuration changes
 * itself (see the manifest), so attaching or removing one reaches `onConfigurationChanged` without a restart.
 */
object HardwareKeyboards {
    fun inUse(config: Configuration): Boolean =
        config.keyboard == Configuration.KEYBOARD_QWERTY &&
            config.hardKeyboardHidden == Configuration.HARDKEYBOARDHIDDEN_NO
}

package com.bundledofflinedocchat

import android.app.Activity
import android.content.Intent
import android.net.Uri
import com.facebook.react.bridge.ActivityEventListener
import com.facebook.react.bridge.BaseActivityEventListener
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.WritableMap
import com.facebook.react.bridge.Arguments
import com.facebook.react.ReactPackage
import com.facebook.react.uimanager.ViewManager
import java.io.File
import java.io.FileOutputStream
import java.util.zip.ZipFile
import org.xmlpull.v1.XmlPullParser
import android.util.Xml
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.text.PDFTextStripper

class DocumentFilePickerModule(private val context: ReactApplicationContext) : ReactContextBaseJavaModule(context) {
  private var pendingPromise: Promise? = null
  private val requestCode = 6421

  private val activityListener: ActivityEventListener = object : BaseActivityEventListener() {
    override fun onActivityResult(activity: Activity, requestCode: Int, resultCode: Int, data: Intent?) {
      if (requestCode != this@DocumentFilePickerModule.requestCode) return
      val promise = pendingPromise ?: return
      pendingPromise = null
      if (resultCode != Activity.RESULT_OK || data?.data == null) {
        promise.resolve(null)
        return
      }
      copySelectedDocument(data.data!!, promise)
    }
  }

  init { context.addActivityEventListener(activityListener) }

  override fun getName() = "DocumentFilePicker"

  @ReactMethod
  fun pickDocument(promise: Promise) {
    if (pendingPromise != null) {
      promise.reject("E_PICKER_BUSY", "A file picker is already open.")
      return
    }
    if (context.currentActivity == null) {
      promise.reject("E_NO_ACTIVITY", "The file picker could not be presented.")
      return
    }
    pendingPromise = promise
    try {
      val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
        addCategory(Intent.CATEGORY_OPENABLE)
        type = "*/*"
      }
      if (!context.startActivityForResult(intent, requestCode, null)) {
        pendingPromise = null
        promise.reject("E_NO_ACTIVITY", "The file picker could not be presented.")
      }
    } catch (error: Exception) {
      pendingPromise = null
      promise.reject("E_PICKER", "The file picker could not be opened.", error)
    }
  }

  private fun copySelectedDocument(uri: Uri, promise: Promise) {
    val displayName = context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
      val index = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
      if (cursor.moveToFirst() && index >= 0) cursor.getString(index) else null
    } ?: "document.txt"
    val safeName = displayName.substringAfterLast('/').substringAfterLast('\\')

    val supported = listOf(".txt", ".md", ".pdf", ".docx").any { safeName.endsWith(it, ignoreCase = true) }
    if (!supported) {
      promise.reject("E_UNSUPPORTED_FILE", "Choose a .txt, .md, .pdf, or Word (.docx) file.")
      return
    }

    try {
      val destination = File(context.cacheDir, "${java.util.UUID.randomUUID()}-$safeName")
      context.contentResolver.openInputStream(uri).use { input ->
        requireNotNull(input) { "The selected file could not be read." }
        FileOutputStream(destination).use { output -> input.copyTo(output) }
      }
      val result: WritableMap = Arguments.createMap().apply {
        putString("path", destination.absolutePath)
        putString("name", displayName)
      }
      promise.resolve(result)
    } catch (error: Exception) {
      promise.reject("E_DOCUMENT_COPY", "The selected file could not be copied into app storage.", error)
    }
  }

  @ReactMethod
  fun extractPdfText(path: String, promise: Promise) {
    try {
      PDFBoxResourceLoader.init(context)
      PDDocument.load(File(path)).use { document ->
        promise.resolve(PDFTextStripper().getText(document))
      }
    } catch (error: Exception) {
      promise.reject("E_PDF_EXTRACTION", "The PDF could not be read. It may be password-protected or damaged.", error)
    }
  }

  @ReactMethod
  fun extractDocxText(path: String, promise: Promise) {
    try {
      val text = ZipFile(path).use { archive ->
        val entry = archive.getEntry("word/document.xml")
          ?: throw IllegalArgumentException("This Word file does not contain readable document text.")
        val parser = Xml.newPullParser()
        parser.setInput(archive.getInputStream(entry), "UTF-8")
        val output = StringBuilder()
        var event = parser.eventType
        while (event != XmlPullParser.END_DOCUMENT) {
          if (event == XmlPullParser.TEXT) output.append(parser.text)
          if (event == XmlPullParser.END_TAG && parser.name == "p") output.append('\n')
          event = parser.next()
        }
        output.toString()
      }
      promise.resolve(text)
    } catch (error: Exception) {
      promise.reject("E_DOCX_EXTRACTION", "The Word document could not be read.", error)
    }
  }
}

class DocumentFilePickerPackage : ReactPackage {
  override fun createNativeModules(context: ReactApplicationContext) = listOf(DocumentFilePickerModule(context))
  override fun createViewManagers(context: ReactApplicationContext): List<ViewManager<*, *>> = emptyList()
}

$ErrorActionPreference = "Stop"

Push-Location $PSScriptRoot\..
try {
    flutter create `
      --project-name local_lens `
      --org com.weepwood `
      --platforms android,windows `
      .

    $manifest = "android\app\src\main\AndroidManifest.xml"
    $content = Get-Content $manifest -Raw
    if ($content -notmatch 'android.permission.INTERNET') {
        $replacement = "<manifest xmlns:android=`"http://schemas.android.com/apk/res/android`">`r`n    <uses-permission android:name=`"android.permission.INTERNET`" />"
        $content = $content -replace '<manifest xmlns:android="http://schemas.android.com/apk/res/android">', $replacement
    }
    if ($content -notmatch 'usesCleartextTraffic') {
        $content = $content -replace '<application', '<application android:usesCleartextTraffic="true"'
    }
    Set-Content $manifest $content -Encoding UTF8

    flutter pub get
    Write-Host "Flutter platform files generated successfully."
}
finally {
    Pop-Location
}

$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'clipwarp-calendar.psm1') -Force
& (Get-Module clipwarp-calendar) {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    function Check($ok,$name) { if (-not $ok) { throw $name }; Write-Host "PASS: $name" }
    # Fake UIA tree: no FromHandle, desktop traversal, clipboard, browser or input.
    function Node($id,$type,$name='',$class='',$value=$null) {
        $n=[pscustomobject]@{
            Id=$id; Children=@(); Value=$value
            Current=[pscustomobject]@{
                ControlType=$type; Name=$name; ClassName=$class; AutomationId=""
                IsOffscreen=$false; IsEnabled=$true; IsKeyboardFocusable=$true; HasKeyboardFocus=$true
            }
        }
        $n | Add-Member ScriptMethod GetRuntimeId { @($this.Id) }
        $n | Add-Member ScriptMethod FindAll { param($scope,$condition) $this.Children }
        $n | Add-Member ScriptMethod TryGetCurrentPattern {
            param($pattern,$result)
            if ($null -eq $this.Value) { return $false }
            $result.Value=[pscustomobject]@{ Current=[pscustomobject]@{ Value=$this.Value } }
            return $true
        }
        $n
    }
    $edit=[Windows.Automation.ControlType]::Edit
    $doc=Node 2 ([Windows.Automation.ControlType]::Document)
    $address=Node 3 $edit 'Address and search bar' '' 'https://gemini.google.com/spark'
    $composer=Node 4 $edit 'Enter a prompt here' 'ql-editor'
    $doc.Children=@($composer)
    $window=Node 1 ([Windows.Automation.ControlType]::Window)
    $window.Children=@($address,$doc,$composer)
    $reader={ param($p) Check ($p.MainWindowHandle -eq 42) 'UIA scoped to exact target HWND'; $window }
    $page=[pscustomobject]@{ MainWindowHandle=[IntPtr]42 }
    $target=Get-ClipwarpGeminiTarget $page -WindowReader $reader
    Check ($target.Id -eq '4' -and $target.Focused) 'composer identified without Document ValuePattern'
    $decoy=Node 7 $edit 'Page search' 'page-input' 'https://gemini.google.com/spark'
    $window.Children=@($decoy,$doc,$composer)
    Check ($null -eq (Get-ClipwarpGeminiTarget $page -WindowReader $reader)) 'exact Spark URL in decoy edit is not an address bar'
    $window.Children=@($address,$doc,$composer)
    foreach ($identity in @('name','class','automation')) {
        $address.Current.Name='Localized address label'; $address.Current.ClassName=''; $address.Current.AutomationId=''
        switch ($identity) {
            'name' { $address.Current.Name='Address and search bar' }
            'class' { $address.Current.ClassName='OmniboxViewViews' }
            'automation' { $address.Current.AutomationId='addressEditBox' }
        }
        Check ($null -ne (Get-ClipwarpGeminiTarget $page -WindowReader $reader)) "$identity browser address identity accepted"
    }
    foreach ($url in @('gemini.google.com/spark','https://gemini.google.com/spark/')) {
        $address.Value=$url
        Check ($null -ne (Get-ClipwarpGeminiTarget $page -WindowReader $reader)) 'address display normalization accepted'
    }
    foreach ($url in @('https://example.com','https://gemini.google.com/app','https://gemini.google.com.evil/spark','https://gemini.google.com/spark?message=secret')) {
        $address.Value=$url
        Check ($null -eq (Get-ClipwarpGeminiTarget $page -WindowReader $reader)) 'wrong tab/URL rejected despite Gemini title'
    }
    $address.Value='https://gemini.google.com/spark'
    $doc.Children=@($composer,$address)
    Check ($null -eq (Get-ClipwarpGeminiTarget $page -WindowReader $reader)) 'web content cannot impersonate browser address bar'
    $doc.Children=@($composer)
    foreach ($mode in @('offscreen','disabled','unfocusable','wrong','ambiguous','missing','document')) {
        $composer.Current.IsOffscreen=$false; $composer.Current.IsEnabled=$true; $composer.Current.IsKeyboardFocusable=$true
        $composer.Current.Name='Enter a prompt here'; $composer.Current.ClassName='ql-editor'
        $doc.Children=@($composer); $window.Children=@($address,$doc,$composer)
        switch ($mode) {
            'offscreen' { $composer.Current.IsOffscreen=$true }
            'disabled' { $composer.Current.IsEnabled=$false }
            'unfocusable' { $composer.Current.IsKeyboardFocusable=$false }
            'wrong' { $composer.Current.Name='Search'; $composer.Current.ClassName='' }
            'ambiguous' { $doc.Children=@($composer,(Node 5 $edit 'Ask Gemini')) }
            'missing' { $doc.Children=@() }
            'document' { $window.Children+=Node 6 ([Windows.Automation.ControlType]::Document) }
        }
        Check ($null -eq (Get-ClipwarpGeminiTarget $page -WindowReader $reader)) "$mode composer/page fails closed"
    }
}

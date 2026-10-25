Set fso = CreateObject("Scripting.FileSystemObject")
strDirectory = fso.GetParentFolderName(WScript.ScriptFullName)
strCommand = """" & fso.BuildPath(strDirectory, "scrcpy.exe") & """"

For Each Arg In WScript.Arguments
    strCommand = strCommand & " """ & replace(Arg, """", """""""""") & """"
Next

Set shell = CreateObject("Wscript.Shell")
shell.CurrentDirectory = strDirectory
shell.Run strCommand, 0, false

# Example array of user IDs
$UserIDs = @(1938,1939,1940)

# Create an empty XML document object
$xml = New-Object System.Xml.XmlDocument

# Build the root <user_group> and child <user_additions> elements
$userGroup = $xml.CreateElement("user_group")
$userAdditions = $xml.CreateElement("user_additions")

# Append the <user_additions> node to <user_group>
[void]$userGroup.AppendChild($userAdditions)
[void]$xml.AppendChild($userGroup)

# Loop through the array and add each user ID
foreach ($id in $UserIDs) {
    $userNode = $xml.CreateElement("user")
    $idNode   = $xml.CreateElement("id")
    $idNode.InnerText = [string]$id

    [void]$userNode.AppendChild($idNode)
    [void]$userAdditions.AppendChild($userNode)
}

# Output or save the final XML
$payload = $xml.OuterXml
$payload | Out-String

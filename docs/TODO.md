exploring ways to improve autop’s anchor estimation by incorporating signal context like rawBpm and histogram scores to better handle tricky cases like musicals. I’m considering
  adding weighted contributions around the plpAnchorBpm using ratio expansions to boost histogram support for target tempos, aiming to blend these factors for a more reliable
  selection without cross-algorithm access.

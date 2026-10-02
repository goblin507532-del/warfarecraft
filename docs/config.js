/* Everything site-specific lives here: fill it in once (or let tools/setup.ps1 do it) and the page picks it up. */
window.WARFARE = {
  site: "warfarecraft.ru",
  ghUser: "goblin507532-del",
  ghRepo: "warfarecraft",
  server: "26.133.174.202:12345",

  /* Donations over SBP, straight to a phone number - works from any Russian bank app. */
  payPhone: "+7 999 892 96 04",
  payPhoneRaw: "79998929604",
  /* Who the payer will see as the recipient; banks show it anyway, this is just so it isn't a surprise. */
  payName: "",
  /* Optional personal payment link from your bank app (T-Bank / Sber "мне переводят" / Alfa).
     Set it, then regenerate the QR: tools\make-pay-qr.ps1 -Link "<this link>" */
  payLink: "",

  donateBoosty: "https://boosty.to/warfarecraft",
  donateAlerts: "",
  donateDirect: "",
  discord: "",
  telegram: ""
};

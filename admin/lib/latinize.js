var reverse_map = {
  A:'ÁĂẮẶẰẲẴǍÂẤẬẦẨẪÄǞȦǠẠȀÀẢȂĀĄÅǺḀȺÃⱯᴀ', AA:'Ꜳ', AE:'ÆǼǢᴁ', AO:'Ꜵ', AU:'Ꜷ',
  AV:'ꜸꜺ', AY:'Ꜽ', B:'ḂḄƁḆɃƂʙᴃ', C:'ĆČÇḈĈĊƇȻꜾᴄ', D:'ĎḐḒḊḌƊḎǲǅĐƋꝹᴅ', DZ:'ǱǄ',
  E:'ÉĔĚȨḜÊẾỆỀỂỄḘËĖẸȄÈẺȆĒḖḔĘɆẼḚƐƎᴇⱻ', ET:'Ꝫ', F:'ḞƑꝻꜰ', G:'ǴĞǦĢĜĠƓḠǤꝽɢʛ',
  H:'ḪȞḨĤⱧḦḢḤĦʜ', I:'ÍĬǏÎÏḮİỊȈÌỈȊĪĮƗĨḬɪ', R:'ꞂŔŘŖṘṚṜȐȒṞɌⱤʁʀᴙᴚ',
  S:'ꞄŚṤŠṦŞŜȘṠṢṨꜱ', T:'ꞆŤŢṰȚȾṪṬƬṮƮŦᴛ', IS:'Ꝭ', J:'ĴɈᴊ', K:'ḰǨĶⱩꝂḲƘḴꝀꝄᴋ',
  L:'ĹȽĽĻḼḶḸⱠꝈḺĿⱢǈŁꞀʟᴌ', LJ:'Ǉ', M:'ḾṀṂⱮƜᴍ', N:'ŃŇŅṊṄṆǸƝṈȠǋÑɴᴎ', NJ:'Ǌ',
  O:'ÓŎǑÔỐỘỒỔỖÖȪȮȰỌŐȌÒỎƠỚỢỜỞỠȎꝊꝌŌṒṐƟǪǬØǾÕṌṎȬƆᴏᴐ', OI:'Ƣ', OO:'Ꝏ', OU:'Ȣᴕ',
  P:'ṔṖꝒƤꝔⱣꝐᴘ', Q:'ꝘꝖ', V:'ɅꝞṾƲṼᴠ', TZ:'Ꜩ',
  U:'ÚŬǓÛṶÜǗǙǛǕṲỤŰȔÙỦƯỨỰỪỬỮȖŪṺŲŮŨṸṴᴜ', VY:'Ꝡ', W:'ẂŴẄẆẈẀⱲᴡ', X:'ẌẊ',
  Y:'ÝŶŸẎỴỲƳỶỾȲɎỸʏ', Z:'ŹŽẐⱫŻẒȤẔƵᴢ', IJ:'Ĳ', OE:'Œɶ',
  a:'áăắặằẳẵǎâấậầẩẫäǟȧǡạȁàảȃāąᶏẚåǻḁⱥãɐₐ', aa:'ꜳ', ae:'æǽǣᴂ', ao:'ꜵ', au:'ꜷ',
  av:'ꜹꜻ', ay:'ꜽ', b:'ḃḅɓḇᵬᶀƀƃ',
  o:'ɵóŏǒôốộồổỗöȫȯȱọőȍòỏơớợờởỡȏꝋꝍⱺōṓṑǫǭøǿõṍṏȭɔᶗᴑᴓₒ', c:'ćčçḉĉɕċƈȼↄꜿ',
  d:'ďḑḓȡḋḍɗᶑḏᵭᶁđɖƌꝺ', i:'ıíĭǐîïḯịȉìỉȋīįᶖɨĩḭᴉᵢ', j:'ȷɟʄǰĵʝɉⱼ', dz:'ǳǆ',
  e:'éĕěȩḝêếệềểễḙëėẹȅèẻȇēḗḕⱸęᶒɇẽḛɛᶓɘǝₑ', et:'ꝫ', f:'ḟƒᵮᶂꝼ',
  g:'ǵğǧģĝġɠḡᶃǥᵹɡᵷ', h:'ḫȟḩĥⱨḧḣḥɦẖħɥʮʯ', hv:'ƕ', r:'ꞃŕřŗṙṛṝȑɾᵳȓṟɼᵲᶉɍɽɿɹɻɺⱹᵣ',
  s:'ꞅſẜẛẝśṥšṧşŝșṡṣṩʂᵴᶊȿ', t:'ꞇťţṱțȶẗⱦṫṭƭṯᵵƫʈŧʇ', is:'ꝭ', k:'ḱǩķⱪꝃḳƙḵᶄꝁꝅʞ',
  l:'ĺƚɬľļḽȴḷḹⱡꝉḻŀɫᶅɭłꞁ', lj:'ǉ', m:'ḿṁṃɱᵯᶆɯɰ', n:'ńňņṋȵṅṇǹɲṉƞᵰᶇɳñ', nj:'ǌ',
  oi:'ƣ', oo:'ꝏ', ou:'ȣ', p:'ṕṗꝓƥᵱᶈꝕᵽꝑ', q:'ꝙʠɋꝗ',
  u:'ᴝúŭǔûṷüǘǚǜǖṳụűȕùủưứựừửữȗūṻųᶙůũṹṵᵤ', th:'ᵺ', oe:'ᴔœ', v:'ʌⱴꝟṿʋᶌⱱṽᵥ',
  w:'ʍẃŵẅẇẉẁⱳẘ', y:'ʎýŷÿẏỵỳƴỷỿȳẙɏỹ', tz:'ꜩ', ue:'ᵫ', um:'ꝸ', vy:'ꝡ',
  x:'ẍẋᶍₓ', z:'źžẑʑⱬżẓȥẕᵶᶎʐƶɀ', ff:'ﬀ', ffi:'ﬃ', ffl:'ﬄ', fi:'ﬁ', fl:'ﬂ',
  ij:'ĳ', st:'ﬆ'
};

var map = {};
Object.keys(reverse_map).forEach((c) => {
  reverse_map[c].split('').forEach((d) => {
    map[d] = c;
  });
});

module.exports = function(str) {
  return this.replace(/[^A-Za-z0-9\[\] ]/g, (c) => map[c] || c);
};

/* ex:set shiftwidth=2: */
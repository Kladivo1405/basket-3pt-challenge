(()=>{'use strict';let host,hud,ribbon,crowdEl,streak=0,misses=0,made=0,total=0,pending=null,hide;
 const audio=(type,v)=>window.BURealAudio?.play(type,v);
 function flash(text){if(!ribbon)return;ribbon.textContent=text;ribbon.classList.add('on');clearTimeout(hide);hide=setTimeout(()=>ribbon?.classList.remove('on'),1600)}
 function detach(){clearTimeout(hide);for(const e of [hud,ribbon,crowdEl])e?.remove();host=hud=ribbon=crowdEl=null;pending=null;streak=misses=made=total=0;window.BURealAudio?.stop()}
 function attach(el,title){detach();if(!el)return;host=el;host.style.position='relative';hud=document.createElement('div');hud.className='bu86hud';hud.innerHTML='<span>BU · TEST ARENA</span><span class="bu86status"></span>';hud.lastChild.textContent=title||'LIVE';ribbon=document.createElement('div');ribbon.className='bu86ribbon';crowdEl=document.createElement('div');crowdEl.className='bu86crowd';host.append(hud,ribbon,crowdEl)}
 function result(hit){if(!host)return;total++;if(hit)made++;streak=hit?streak+1:0;misses=hit?0:misses+1;const label=hud.querySelector('.bu86status');label.textContent=pending?`SCORE ${pending.score} · ${pending.made} MADE`:`${made} / ${total} MADE`;label.classList.toggle('bu86fire',streak>=3);pending=null;
 if(hit){if(streak>=3&&streak%3===0){flash('MVP! MVP!');audio('mvp',.9)}else audio('cheer',.5)}else if(misses>=3&&misses%3===0){flash('BOOOOO!');audio('boo',.85)}
 if(crowdEl){crowdEl.classList.toggle('loud',hit);setTimeout(()=>crowdEl?.classList.remove('loud'),1200)}}
 window.BUArena={get host(){return host},attach,detach,shot(hit,made,missed,score){pending={hit,made,score}},impact(){},ftShot:result,clock(n){if(n>0&&n<=5)flash(String(Math.ceil(n)))},result};
 if(window.FTAnim){const mount=FTAnim.mount,destroy=FTAnim.destroy;FTAnim.mount=function(el,options){const value=mount.apply(this,arguments);attach(el,el.id==='bu3ptCourt'?'3PT CONTEST':options?.defender?'BLOCKOUT':'FREE THROW');return value};FTAnim.destroy=function(){detach();return destroy.apply(this,arguments)}}
})();

/* ###################################################################

TradeSync MT4 Receiver from Socket Connection

Receives messages from "TradeSync Hub" and Places Trades to MT4 account.

In addition, you can telnet into the server's port.
Message Format to be interpreted by this Listener is as follows:

Message line (after \r\n) must Start with "TradeSyncCommand" and have the following fields:
Action
Command
Open Price
TakeProfit
StopLoss
Volume
Each Command is a member in a array and must be opened with "{" and closed with "}"
the separator between a parameter name and a parameter value is ":"
the separator between parameters is ","
Command line ends when finds a \r\n

Make sure there is no conflict with the following 6 symbols in this command: } { , " : \r\n

Example of a Command is :

TradeSyncCommand {   :    ,    :   ,     :    },{   :    ,    :   ,     :    }

################################################################### */


#property strict

// --------------------------------------------------------------------
// Include socket library, asking for event handling
// --------------------------------------------------------------------

#define SOCKET_LIBRARY_USE_EVENTS
#include <socket-library-mt4-mt5.mqh>

// --------------------------------------------------------------------
// EA user inputs
// --------------------------------------------------------------------

input string HubAddress = "http://thecoder1.pythonanywhere.com:80"; // Cloud Hub, to connect Signal Receiver
input ushort   ServerPort = 23456;  // Server port to listen to, on this computer (Port must be Open)
input string FromAccount = "00000000"; //Account from which Trading Signal should be copied
input double VolumeMultiplier=1 ; //Volume multiplier after considering equity rule

// --------------------------------------------------------------------
// Global variables and constants
// --------------------------------------------------------------------

// Frequency for EventSetMillisecondTimer(). Doesn't need to
// be very frequent, because it is just a back-up for the
// event-driven handling in OnChartEvent()
#define TIMER_FREQUENCY_MS    1000
#include <Arrays\ArrayString.mqh>

// Server socket
ServerSocket * glbServerSocket = NULL;

// Array of current clients
ClientSocket * glbClients[];

// Watch for need to create timer;
bool glbCreatedTimer = false;
CArrayString *arraySPMessage=new CArrayString;   //Messages for Status Pannel
CArrayString *arraySPValue  =new CArrayString;     // Values for Status Panel


// --------------------------------------------------------------------
// Initialisation - set up server socket
// --------------------------------------------------------------------

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void OnInit()
  {
//   Print("Inicializando 16");
// If the EA is being reloaded, e.g. because of change of timeframe,
// then we may already have done all the setup. See the
// termination code in OnDeinit.
   TradeSyncSubscribe();
   StartServer();
   UpdateStatus("Server Started at GMT Time ", TimeToStr(TimeGMT(),TIME_DATE|TIME_SECONDS));
   //UpdateStatus("Listening on port ",IntegerToString(ServerPort));
   UpdateStatus("My IP Address ","is unknown, listening on port "+IntegerToString(ServerPort));
  }


//---------------------------------------------------------------------
// Starts the Server to Listen to Port
//---------------------------------------------------------------------
void StartServer()
  {
   if(glbServerSocket)
     {
      Print("Reloading EA with existing server socket");
     }
   else
     {
      // Create the server socket
      glbServerSocket = new ServerSocket(ServerPort, false);
      if(glbServerSocket.Created())
        {
         Print("Server socket created");

         // Note: this can fail if MT4/5 starts up
         // with the EA already attached to a chart. Therefore,
         // we repeat in OnTick()
         glbCreatedTimer = EventSetMillisecondTimer(TIMER_FREQUENCY_MS);
        }
      else
        {
         Print("Server socket FAILED - is the port already in use?");
        }
     }
  }
// --------------------------------------------------------------------
// Termination - free server socket and any clients
// --------------------------------------------------------------------

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   switch(reason)
     {
      case REASON_CHARTCHANGE:
         // Keep the server socket and all its clients if
         // the EA is going to be reloaded because of a
         // change to chart symbol or timeframe
         break;

      default:
         // For any other unload of the EA, delete the
         // server socket and all the clients
         glbCreatedTimer = false;

         // Delete all clients currently connected
         for(int i = 0; i < ArraySize(glbClients); i++)
           {
            delete glbClients[i];
           }
         ArrayResize(glbClients, 0);

         // Free the server socket. *VERY* important, or else
         // the port number remains in use and un-reusable until
         // MT4/5 is shut down
         delete glbServerSocket;
         Print("Server socket terminated");
         delete arraySPMessage;
         delete arraySPValue;

         break;
     }
  }


// --------------------------------------------------------------------
// Timer - accept new connections, and handle incoming data from clients.
// Secondary to the event-driven handling via OnChartEvent(). Most
// socket events should be picked up faster through OnChartEvent()
// rather than being first detected in OnTimer()
// --------------------------------------------------------------------

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void OnTimer()
  {
// Accept any new pending connections
   AcceptNewConnections();

// Process any incoming data on each client socket,
// bearing in mind that HandleSocketIncomingData()
// can delete sockets and reduce the size of the array
// if a socket has been closed

   for(int i = ArraySize(glbClients) - 1; i >= 0; i--)
     {
      HandleSocketIncomingData(i);
     }
  }


// --------------------------------------------------------------------
// Accepts new connections on the server socket, creating new
// entries in the glbClients[] array
// --------------------------------------------------------------------

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void AcceptNewConnections()
  {
// Keep accepting any pending connections until Accept() returns NULL
   ClientSocket * pNewClient = NULL;
   do
     {
      pNewClient = glbServerSocket.Accept();
      if(pNewClient != NULL)
        {
         int sz = ArraySize(glbClients);
         ArrayResize(glbClients, sz + 1);
         glbClients[sz] = pNewClient;
         Print("New client connection", glbClients[sz]);

         pNewClient.Send("Hello\r\n");
        }

     }
   while(pNewClient != NULL);
  }


// --------------------------------------------------------------------
// Handles any new incoming data on a client socket, identified
// by its index within the glbClients[] array. This function
// deletes the ClientSocket object, and restructures the array,
// if the socket has been closed by the client
// --------------------------------------------------------------------

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void HandleSocketIncomingData(int idxClient)
  {
   ClientSocket * pClient = glbClients[idxClient];

// Keep reading CRLF-terminated lines of input from the client
// until we run out of new data
   bool bForceClose = false; // Client has sent a "close" message
   string strCommand;
   do
     {
      strCommand = pClient.Receive("\r\n");
      if(strCommand == "close") bForceClose = true;
      else if(StringFind(strCommand, "TradeSyncRequest") >= 0) interpretTradeSyncCommand(strCommand);
      else if(StringFind(strCommand, "TradeSyncSummary") >= 0) interpretTradeSyncSummary(strCommand);
      else if(StringFind(strCommand, "Host:") >= 0) UpdateStatus("My IP Address ",strCommand);
      else if(strCommand != "") Print("Remote Command not Recognized: ", strCommand);
     }
   while(strCommand != "");

// If the socket has been closed, or the client has sent a close message,
// release the socket and shuffle the glbClients[] array
   if(!pClient.IsSocketConnected() || bForceClose)
     {
      Print("Client has disconnected");

      // Client is dead. Destroy the object
      delete pClient;

      // And remove from the array
      int ctClients = ArraySize(glbClients);
      for(int i = idxClient + 1; i < ctClients; i++)
        {
         glbClients[i - 1] = glbClients[i];
        }
      ctClients--;
      ArrayResize(glbClients, ctClients);
     }
  }


// --------------------------------------------------------------------
// Use OnTick() to watch for failure to create the timer in OnInit()
// --------------------------------------------------------------------

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!glbCreatedTimer)
      glbCreatedTimer = EventSetMillisecondTimer(TIMER_FREQUENCY_MS);

  }


//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long& lparam, const double& dparam, const string& sparam)
  {
   if(id == CHARTEVENT_KEYDOWN)
     {

      if(lparam == glbServerSocket.GetSocketHandle())
        {
         // Activity on server socket. Accept new connections
         Print("New server socket event - incoming connection");
         AcceptNewConnections();

        }
      else
        {
         // Compare lparam to each client socket handle
         for(int i = 0; i < ArraySize(glbClients); i++)
           {
            if(lparam == glbClients[i].GetSocketHandle())
              {
               HandleSocketIncomingData(i);
               return; // Early exit
              }
           }

        }
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void interpretTradeSyncCommand(string TSCommand)
  {
   UpdateStatus("Latest Listened Signal: ", TimeToStr(TimeCurrent(),TIME_DATE|TIME_SECONDS));
   Print("Interpreting command "+ TSCommand);
   for(int i=0; i<CountArrayMembers(TSCommand); i++)
     {

      // Extracting necessary Variables from TSCommand
      int TSID       =            StringToInteger(ExtractValue(TSCommand, "TR_ID",          i));                //ok
      string TSAction   =                         ExtractValue(TSCommand, "ACTION",          i);                //ok
      string TSSymbol   =               SymbolMap(ExtractValue(TSCommand, "SYMBOL",         i));                //ok
      int    TSOrderNum =         StringToInteger(ExtractValue(TSCommand, "ORD_NUM",        i));                //ok
      int    TSPosNum   =         StringToInteger(ExtractValue(TSCommand, "POS",            i));                //ok
      int    TSPosByNum =         StringToInteger(ExtractValue(TSCommand, "POS_BY",         i));                //ok
      datetime TSTimeGMT=            StringToTime(ExtractValue(TSCommand, "T_GMT",          i));                //ok
      int    TSTypeOrder=         Convert2MQL4Cmd(ExtractValue(TSCommand, "ORD_TYPE",       i));                //ok
      double TSEquity   =          StringToDouble(ExtractValue(TSCommand, "ACC_EQ",         i));                //ok
      double TSVolume   =  NormalizeDouble(CalcVol(StringToDouble(ExtractValue(TSCommand, "VOLUME",i)), TSEquity),2);     //ok
      double TSPrice    =          StringToDouble(ExtractValue(TSCommand, "PRICE",          i));                //ok
      double TSStopLimit=          StringToDouble(ExtractValue(TSCommand, "STOP_LIMIT",     i));                //ok
      double TSTP       =          StringToDouble(ExtractValue(TSCommand, "TP",             i));                //ok
      double TSSL       =          StringToDouble(ExtractValue(TSCommand, "SL",             i));                //ok

      //Showing on Screen what was extracted
      Print("Membro indice ",i," da Array tem Ticket Numero ", TSOrderNum, " Simbolo ",TSSymbol,", Type is ", IntegerToString(TSTypeOrder));

      //Interpreting and executing Commands
      //Interpreting and executing Commands
      if(TSAction == "TRADE_ACTION_DEAL")
        {
         if((TSOrderNum == 0) && (TSPosNum==0))         // Ignorar, Ordem invalida sem possibilidade de tracking
           {
            return;  // Simply go back, no trade to be done
           }
         else
            if((TSPosNum==0))                        // Abrir Nova Posicao
              {
               MyOrderSend(TSID, TSOrderNum, TSSymbol, TSTypeOrder,TSPrice, TSVolume, TSTP, TSSL);
              }
            else
               if(TSPosNum != 0)                         // Fechar Posicao
                 {
                  MyOrderClose(TSID,TSPosNum,TSVolume,TSPrice);
                 }
        }
      else
         if(TSAction== "TRADE_ACTION_PENDING")
           {
            MyOrderSend(TSID,TSOrderNum,TSSymbol, TSTypeOrder, TSPrice, TSVolume, TSTP, TSSL);
           }
         else
            if(TSAction== "TRADE_ACTION_SLTP")
              {
               MyOrderModify(TSID, TSPosNum, TSPrice, TSSL, TSTP);
              }
            else
               if(TSAction=="TRADE_ACTION_MODIFY")
                 {
                  MyOrderModify(TSID, TSPosNum, TSPrice, TSSL, TSTP);
                 }
               else
                  if(TSAction=="TRADE_ACTION_REMOVE")
                    {
                     MyOrderDelete(TSID, TSPosNum);
                    }
                  else
                     if(TSAction=="TRADE_ACTION_CLOSE_BY")
                       {
                        MyOrderCloseBy(TSID,TSPosNum,TSVolume,TSPrice, TSPosByNum);
                       }

     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void interpretTradeSyncSummary(string TSSummary)
  {


  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
string ExtractValue(string FromString, string ParamString, int ArrayIndex=0, string ECommand="TradeSyncRequest", string Delimiter="}")
  {
//Print("Begin of ExtractValue for ", ParamString, " ArrayIndex ", ArrayIndex);
//InsertCodes to skip to x member in Array
   int BeginPosArrayMember=(StringFind(FromString, ECommand,0));
   if(BeginPosArrayMember<0)
     {
      Print(ECommand, " Command String not found while seeking parameter ",ParamString);
      return "";
     };
   BeginPosArrayMember=BeginPosArrayMember+ StringLen(ECommand);
   int EndPosArrayMember = -1;
   int ArrayMemberCount=0;
   for(int i=0; i<=ArrayIndex; i++)
     {
      BeginPosArrayMember=StringFind(FromString,"[{",BeginPosArrayMember +1);
      if(BeginPosArrayMember<=0)
         return "";                                  // This member Does not exist in Array... Index out of Array
      EndPosArrayMember=StringFind(FromString,"}]",BeginPosArrayMember+1);
      if(EndPosArrayMember<=0)
         return "";
      //Print("Looping through Array. i= ",i, " Begin Position of Array Member is ",BeginPosArrayMember," End Position of Array Member is ", EndPosArrayMember);
     }



   int BeginPos = (StringFind(FromString,ParamString,BeginPosArrayMember));
   if(BeginPos<=0)
     {
      Print("ParamString ",ParamString," not found in string");
      return "";
     }
   //BeginPos = BeginPos+StringLen(ParamString);
   BeginPos = StringFind(FromString,":",BeginPos)+1;    //Move pointer to after ":"
   int EndPos = StringFind(FromString, Delimiter, BeginPos);
   int EndItem = EndPosArrayMember;
   if((EndPos>0) &&(EndItem>0))
      EndPos=MathMin(EndPos,(EndItem));
   if(BeginPos>=EndItem)
     {
      Print("BeginPos>=EndItem, Halting. BeginPos=",BeginPos," EndPos= ",EndItem);   // Item does not exist in this array member
      return "";
     }
   string result = StringSubstr(FromString, BeginPos, EndPos - BeginPos);
   //Cleaning up the resulting string
   //StringReplace(result," ","");
   //Print("xx"+result+"xx");
   StringReplace(result,"}","");
   StringReplace(result,"\"","");
   StringReplace(result,"\\","");
   if(StringSubstr(result,0,1)==" ") result = StringSubstr(result,1,StringLen(result)-1);
   Print("Extracted Param ", ParamString," as ",result);
   return result;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int CountArrayMembers(string Message)   //Will Count Members in a 1 level array and return the count, or return -1 if error
  {
   int countOpen=0;
   int countClose=0;
   int Position = StringFind(Message,"TradeSyncRequest",0)+StringLen("TradeSyncRequest");
   do
     {
      Position=StringFind(Message,"[{", Position+1);
      if(Position>0)                             //In case of finding another opening
        {
         (countOpen++);
        }
      else
        {
         break;
        }
      Position=StringFind(Message,"}]", Position+1);
      if(Position>0)                             //In case of finding another Closing
        {
         (countClose++);
        }
      else
        {
         break;
        }
     }
   while(true);
   if(countClose==countOpen)
     {
      return countOpen;
     }
   else
     {
      return -1;
     }
  }

//+------------------------------------------------------------------+
//-------Function to send orders
//+------------------------------------------------------------------+
int MyOrderSend(int MOSTrID, int MOSTrTicket, string MOSSymbol,int MOSCMD, double MOSOpenPrice, double MOSVolume, double MOSTP, double MOSSL)
  {
   Print("Starting MyOrderSend");
//string O_comment=("TrID=" +MOSTrID+" TrTik="+ IntegerToString(MOSTrTicket)+" TradeSync Receiver");
   if (!((FromAccount == MOSTrID) || (FromAccount == "ALL"))) return -2; // Signal doesn't belong to the accounts being copied, do not copy.
   int MagicNum = TikToMagic(MOSTrID,MOSTrTicket);
   return OrderSend(MOSSymbol, MOSCMD, MOSVolume, MOSOpenPrice, 20, MOSSL, MOSTP, "", MagicNum);
  }

//+------------------------------------------------------------------+
//-------Function to Delete orders
//+------------------------------------------------------------------+
void MyOrderDelete(int MODTrID, int MODTrOrdNum)
  {
   Print("Starting MyOrderDelete");
   OrderDelete(SeekTransmitterTicket(MODTrID, MODTrOrdNum));
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void MyOrderModify(int MOMID, int MOMPosNum, double MOMPrice, double MOMSL, double MOMTP)
  {
   Print("Starting MyOrderModify");
   OrderModify(SeekTransmitterTicket(MOMID, MOMPosNum),MOMPrice,MOMSL,MOMTP, 0);
  }

//+------------------------------------------------------------------+
//---------- Function to wrap OrderClose
//+------------------------------------------------------------------+
void MyOrderClose(int MOC_ID, int MOC_PosNum, double MOC_Vol,double MOC_Price, int MOC_Slippage = 20)
  {
   Print("Starting MyOrderClose");
   OrderClose(SeekTransmitterTicket(MOC_ID, MOC_PosNum), MOC_Vol, MOC_Price,MOC_Slippage);

  }
//+------------------------------------------------------------------+
//---------- Function to wrap OrderCloseBy
//+------------------------------------------------------------------+
void MyOrderCloseBy(int MOC_ID, int MOC_PosNum, double MOC_Vol,double MOC_Price, int CloseByNum, int MOC_Slippage = 20)
  {
   Print("Starting MyOrderCloseBy");
   OrderCloseBy(SeekTransmitterTicket(MOC_ID, MOC_PosNum), SeekTransmitterTicket(MOC_ID, CloseByNum));

  }

//+------------------------------------------------------------------------
// Function to update a Status Panel with info
//+------------------------------------------------------------------------
void UpdateStatus(string SPMessage, string SPValue)
  {
   int SPindex = arraySPMessage.SearchLinear(SPMessage);
   if(SPindex ==-1)
     {
      // Create Element
      arraySPMessage.Add(SPMessage);
      arraySPValue.Add(SPValue);
     }
   else
     {
      //Substitute Element
      arraySPValue.Update(SPindex,SPValue);
     }
   int SPlines=arraySPMessage.Total();
   string StatusMessage="";

   for(int i=0; i<SPlines ; i++)
     {
      StatusMessage=StatusMessage + arraySPMessage[i]+" "+arraySPValue[i]+"\n";
     }
   Comment(StatusMessage);

   return;
  }


//------ Seek Transmitter Ticket within the Active Orders if named in comment
int SeekTransmitterTicket(int TrID, long TrOrdNum)
  {
   for(int i=0; i<OrdersTotal(); i++)
     {
      if(OrderSelect(i, 0, 0))
        {
         if(OrderMagicNumber() == TikToMagic(TrID,TrOrdNum))
            return OrderTicket();

        }
     }
   return -1; //Not Found
  }
//----------------------------Code used to reduce legth of TRiD to 2 digits. /
int TikToMagic(int ID, int Tik)
  {
   string IDstring = IntegerToString(ID);
   string Tikstring = IntegerToString(Tik);
   int Last2ID = StringToInteger(StringSubstr(IDstring,StringLen(IDstring)-2,2));
   int Last2Tik = StringToInteger(StringSubstr(Tikstring,StringLen(Tikstring)-2,2));
   while(ID >=10)
     {
      ID = ID/9;
     }
   while(Tik >= 10000)
     {
      Tik = Tik/9;
     }
   return ((((ID*100)+Last2ID)*1000000)+((Tik*100)+Last2Tik));
  }
//------ Function to Map Symbol Names, according to each broker's standards
string SymbolMap(string SMSymbol)
  {
// Calculate Symbol Mapping here
   return SMSymbol;
  }
//+-------------------------------------------------------------------
// Converts MQL5 Order Type into Alveo Command Type
//+-------------------------------------------------------------------
int Convert2MQL4Cmd(string MQL5OrderType)
  {
   //StringReplace(MQL5OrderType," ","");
   if(MQL5OrderType == "ORDER_TYPE_BUY")             return 0;
   if(MQL5OrderType == "ORDER_TYPE_SELL")            return 1;
   if(MQL5OrderType == "ORDER_TYPE_BUY_LIMIT")       return 2;
   if(MQL5OrderType == "ORDER_TYPE_SELL_LIMIT")      return 3;
   if(MQL5OrderType == "ORDER_TYPE_BUY_STOP")        return 4;
   if(MQL5OrderType == "ORDER_TYPE_SELL_STOP")       return 5;
   if(MQL5OrderType == "ORDER_TYPE_BUY_STOP_LIMIT")  return 4;
   if(MQL5OrderType == "ORDER_TYPE_SELL_STOP_LIMIT") return 5;
   if(MQL5OrderType == "POSITION_TYPE_BUY")          return 0;
   if(MQL5OrderType == "POSITION_TYPE_SELL")         return 1;
   return -10; //Code should never reach this spot
  }

//------ Calculates Trade Volume for the order
double CalcVol(double RVol, double REquity)
  {
   double cAccountEquity=AccountInfoDouble(ACCOUNT_EQUITY);
   return ((VolumeMultiplier * cAccountEquity * RVol)/REquity);
  }


//--------------------------------
// Function to Subscribe to TradeSyncHub
//----------------------------------
bool TradeSyncSubscribe()
  {
   string cookie=NULL, headers;
   char post[], result[];
   int res;
   int timeout=5000;
   string SubscribeMessage= "TradeSync_SubscribeMe [{\"MyPortIs\":"+IntegerToString(ServerPort)+"}]";
   StringToCharArray(SubscribeMessage,post);
   Print("Contacting "+HubAddress+" to request subscription");
   res=WebRequest("POST", HubAddress, cookie, NULL, timeout, post, 0, result, headers);
//--- Checking errors
   if(res==-1)
     {
      Print("Error in Subscription Request. Error code  =",GetLastError());
      //--- Perhaps the URL is not listed, display a message about the necessity to add the address
      MessageBox("Add the address '"+StringSubstr(HubAddress,0,StringFind(HubAddress,":"))+"', in the list of allowed URLs on tab 'Expert Advisors'","Error",MB_ICONINFORMATION);
      return false;
     }
   else
     {
      //--- Load successfully
      Print("Successful subscription to ", HubAddress, " Server Response was ", CharArrayToString(result));
      //PrintFormat("The file has been successfully loaded, File size =%d bytes.",ArraySize(result));
      //--- Save the data to a file
      //int filehandle=FileOpen("GoogleFinance.htm",FILE_WRITE|FILE_BIN);
      //--- Checking errors
      //if(filehandle!=INVALID_HANDLE)
      //{
      //--- Save the contents of the result[] array to a file
      //FileWriteArray(filehandle,result,0,ArraySize(result));
      //--- Close the file
      //FileClose(filehandle);
      //   }
      //else Print("Error in FileOpen. Error code=",GetLastError());
      return true;
     }

  }
//+------------------------------------------------------------------+
